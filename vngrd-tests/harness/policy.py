"""The security contract, parsed from the build's own configuration.

This module exists to end the class of failure where a case hardcodes an
expectation that the image no longer holds -- the old PCR 5 contradiction, where one
case asserted the seal named PCR 5, another asserted it did not, and the
effective command line said `--tpm2-pcrs=7`.

Everything policy-shaped is read from one place: mkosi.conf and its drop-ins,
the repart definitions, and the effective systemd-repart command line. Cases
assert against `policy.<field>`, never against a literal.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from .errors import ConfigError
from .paths import Paths
from .util import parse_scalars


def parse_ini(path: Path) -> dict[str, dict[str, str]]:
    """A forgiving INI reader: last value wins, no interpolation, no strictness."""
    sections: dict[str, dict[str, str]] = {}
    current = ""
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith(";"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections.setdefault(current, {})
            continue
        if "=" in line and current:
            key, value = line.split("=", 1)
            sections[current][key.strip()] = value.strip()
    return sections


def merge_ini(base: dict[str, dict[str, str]], override: dict[str, dict[str, str]]) -> None:
    for section, values in override.items():
        base.setdefault(section, {}).update(values)


def _setting(sections: dict[str, dict[str, str]], section: str, key: str, default: str = "") -> str:
    return sections.get(section, {}).get(key, default)


def _validation(sections: dict[str, dict[str, str]], key: str, default: str = "") -> str:
    """Read a Validation key, falling back to Content for older layouts."""
    return _setting(sections, "Validation", key) or _setting(sections, "Content", key, default)


@dataclass
class Policy:
    paths: Paths
    image_id: str
    version: str
    kernel_cmdline: str
    # effective policy, from the systemd-repart command line (it overrides the
    # partition definition)
    pcr_mask: frozenset[int]
    pubkey_pcr_mask: frozenset[int]
    policy_authorize: bool
    pcrlock_disabled: bool
    # declared in /usr/lib/repart.d/10-root.conf
    definition_pcr_mask: frozenset[int]
    # the root is re-sealed against a systemd-pcrlock policy on the boot that
    # provisions, and the window both make-policy runs use
    pcrlock_enrolled: bool
    pcrlock_window: str
    phases: tuple[str, ...]
    sign_expected_pcr: bool
    secureboot: bool
    secureboot_auto_enroll: bool
    secureboot_sign_tool: str
    verity: str
    extra_search_paths: tuple[str, ...]
    # signing material, as named by the local (gitignored) key drop-in
    secureboot_cert: str = ""
    secureboot_key: str = ""
    pcr_cert: str = ""
    pcr_key: str = ""
    repart_sizes: dict[str, str] = field(default_factory=dict)
    repart_labels: tuple[str, ...] = ()
    source_notes: dict[str, str] = field(default_factory=dict)


    @classmethod
    def load(cls, paths: Paths) -> "Policy":
        mkosi = paths.image_src / "mkosi.conf"
        if not mkosi.is_file():
            raise ConfigError("no %s; is VNGRO_REPO right?" % mkosi)
        sections = parse_ini(mkosi)
        for dropin in sorted((paths.image_src / "mkosi.conf.d").glob("*.conf")):
            merge_ini(sections, parse_ini(dropin))

        repart_pcr_mask, pubkey_pcr_mask, policy_authorize, pcrlock_disabled = _parse_repart(paths)
        definition_pcr_mask = _parse_definition(paths)
        pcrlock_window, pcrlock_enrolled = _parse_pcrlock(paths)

        return cls(
            paths=paths,
            image_id=_setting(sections, "Output", "ImageId", "vngrd"),
            version=_setting(sections, "Output", "ImageVersion", "0.1"),
            kernel_cmdline=_setting(sections, "Content", "KernelCommandLine"),
            pcr_mask=frozenset(repart_pcr_mask),
            pubkey_pcr_mask=frozenset(pubkey_pcr_mask),
            policy_authorize=policy_authorize,
            pcrlock_disabled=pcrlock_disabled,
            definition_pcr_mask=frozenset(definition_pcr_mask),
            pcrlock_enrolled=pcrlock_enrolled,
            pcrlock_window=pcrlock_window,
            phases=_parse_phases(paths),
            sign_expected_pcr=_validation(sections, "SignExpectedPcr").lower() == "yes",
            secureboot=_validation(sections, "SecureBoot").lower() == "yes",
            secureboot_auto_enroll=_validation(sections, "SecureBootAutoEnroll").lower() == "yes",
            secureboot_sign_tool=_validation(sections, "SecureBootSignTool", "systemd-sbsign"),
            verity=_validation(sections, "Verity"),
            extra_search_paths=tuple(
                _setting(sections, "Build", "ExtraSearchPaths").replace(",", " ").split()
            ),
            secureboot_cert=_validation(sections, "SecureBootCertificate"),
            secureboot_key=_validation(sections, "SecureBootKey"),
            pcr_cert=_validation(sections, "SignExpectedPcrCertificate"),
            pcr_key=_validation(sections, "SignExpectedPcrKey"),
            repart_sizes=_parse_repart_sizes(paths),
            repart_labels=_parse_repart_labels(paths),
            source_notes={
                "repart_dropin": str(_repart_dropin(paths)),
                "repart_definition": str(_repart_definition(paths)),
                "ukify": str(paths.image_src / "scripts" / "ukify"),
            },
        )


    @property
    def cmdline_entries(self) -> list[str]:
        return self.kernel_cmdline.split()

    def cmdline_option(self, name: str) -> str | None:
        prefix = name + "="
        for entry in self.cmdline_entries:
            if entry.startswith(prefix):
                return entry[len(prefix) :]
        return None

    @property
    def lockdown_mode(self) -> str | None:
        return self.cmdline_option("lockdown")

    @property
    def pcr_mask_text(self) -> str:
        return ",".join(str(pcr) for pcr in sorted(self.pcr_mask))

    @property
    def pubkey_pcr_mask_text(self) -> str:
        return ",".join(str(pcr) for pcr in sorted(self.pubkey_pcr_mask))

    def disagreements(self) -> list[str]:
        """Places where the build contradicts itself.

        Returned rather than raised: the caller decides whether a particular
        inconsistency is a test failure. A non-empty list means the artefact's
        security posture is ambiguous, which is exactly the state that produced
        the old PCR 5 contradictions.
        """
        out: list[str] = []
        if self.definition_pcr_mask and self.definition_pcr_mask != self.pcr_mask:
            out.append(
                "repart definition TPM2PCRs=%s but effective --tpm2-pcrs=%s"
                % (sorted(self.definition_pcr_mask), sorted(self.pcr_mask))
            )
        if self.policy_authorize and 11 not in self.pubkey_pcr_mask:
            out.append("PolicyAuthorize is enabled but --tpm2-public-key-pcrs does not name 11")
        if not self.policy_authorize:
            out.append("no --tpm2-public-key=: the seal degrades to a bare PolicyPCR")
        if not self.sign_expected_pcr:
            out.append("SignExpectedPcr is off: no .pcrsig, so PolicyAuthorize cannot be satisfied")
        return out




def _repart_dropin(paths: Paths) -> Path:
    candidates = [
        paths.initrd_out / "usr/lib/systemd/system/systemd-repart.service.d/10-device.conf",
        paths.rootfs_out / "usr/lib/systemd/system/systemd-repart.service.d/10-device.conf",
        paths.image_src
        / ".."
        / "vngrd-rootfs/packages/base-files/files/usr/lib/systemd/system/systemd-repart.service.d/10-device.conf",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise ConfigError("cannot find the systemd-repart 10-device.conf drop-in")


def _repart_definition(paths: Paths) -> Path:
    candidates = [
        paths.rootfs_out / "usr/lib/repart.d/10-root.conf",
        paths.image_src
        / ".."
        / "vngrd-rootfs/packages/base-files/files/usr/lib/repart.d/10-root.conf",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise ConfigError("cannot find /usr/lib/repart.d/10-root.conf")


def _exec_start(paths: Paths) -> str:
    text = _repart_dropin(paths).read_text()
    for line in text.splitlines():
        if line.startswith("ExecStart=systemd-repart"):
            return line
    raise ConfigError("no ExecStart=systemd-repart line in %s" % _repart_dropin(paths))


def _parse_repart(paths: Paths) -> tuple[list[int], list[int], bool, bool]:
    line = _exec_start(paths)

    def option(name: str) -> str | None:
        match = re.search(r"--%s=(\S*)" % re.escape(name), line)
        return match.group(1) if match else None

    pcr_text = option("tpm2-pcrs") or ""
    pubkey_pcr_text = option("tpm2-public-key-pcrs") or ""
    public_key = option("tpm2-public-key") or ""
    pcrlock = option("tpm2-pcrlock")
    return (
        parse_scalars(pcr_text),
        parse_scalars(pubkey_pcr_text),
        bool(public_key),
        pcrlock is not None,
    )


def _enrollment_unit(paths: Paths) -> Path:
    """The initrd's enrollment unit, where a pcrlock token is written."""
    candidates = [
        paths.initrd_out / "usr/lib/systemd/system/vngrd-tpm-pcrlock.service",
        paths.rootfs_out / "usr/lib/systemd/system/vngrd-tpm-pcrlock.service",
        paths.image_src
        / ".."
        / "vngrd-rootfs/packages/base-files/files/usr/lib/systemd/system/vngrd-tpm-pcrlock.service",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise ConfigError("cannot find vngrd-tpm-pcrlock.service (the pcrlock enrollment unit)")


def _host_unit(paths: Paths, name: str) -> Path | None:
    candidates = [
        paths.rootfs_out / "usr/lib/systemd/system" / name,
        paths.image_src / ".." / "vngrd-rootfs/packages/base-files/files/usr/lib/systemd/system" / name,
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None


def _components_list(path: Path | None) -> list[str]:
    """Every --components= directory named in a unit or drop-in, in order.

    --components replaces the search path rather than adding to it, so a side
    that names none reads the default set -- which includes /var/lib/pcrlock.d on
    the host and, in the initrd, a /usr/lib/pcrlock.d that does not exist.
    """
    if path is None or not path.is_file():
        return []
    found = []
    for line in path.read_text().splitlines():
        if not line.startswith("ExecStart"):
            continue
        for match in re.finditer(r"--components=([\w./-]+)", line):
            found.append(match.group(1))
    return found
    for line in path.read_text().splitlines():
        if not line.startswith("ExecStart"):
            continue
        match = re.search(r"--components=([\w./-]+)", line)
        if match:
            return match.group(1)
    return ""


def _pcrs_from(path: Path | None) -> str | None:
    """The --pcr= selection in a unit or drop-in, or None if there is none."""
    if path is None or not path.is_file():
        return None
    for line in path.read_text().splitlines():
        if not line.startswith("ExecStart"):
            continue
        match = re.search(r"--pcr=([\d,]+)", line)
        if match:
            return match.group(1)
    return None


def _window_from(path: Path | None) -> str:
    """The --location= string in a unit or drop-in, or "" if there is none.

    Both make-policy runs must name the same window; that is what makes the
    host's refresh able to satisfy the enrollment's policy.
    """
    if path is None or not path.is_file():
        return ""
    # Only ExecStart= lines count: a drop-in's comments quote upstream's own
    # window to explain why it is being replaced, and matching those would have
    # the tool disagree with itself on every run.
    for line in path.read_text().splitlines():
        # ExecStartPre= is the enrollment's spelling (the whole enrollment is
        # ExecStartPre steps ending in the cryptenroll).
        if not line.startswith("ExecStart"):
            continue
        match = re.search(r"--location=([\w.:-]+)", line)
        if match:
            return match.group(1)
    return ""
    return match.group(1) if match else ""


def _parse_pcrlock(paths: Paths) -> tuple[str, bool]:
    unit = _enrollment_unit(paths)
    text = unit.read_text()
    enrolled = "--tpm2-pcrlock=" in text
    window = _window_from(unit)
    # The enrollment window has to be the one the host refresh uses, or the two
    # runs of make-policy argue about different components and the policy changes
    # shape between the boot that installs it and the boot that refreshes it.
    host_dropin = _host_unit(paths, "systemd-pcrlock-make-policy.service.d/10-vngrd.conf")
    host_window = _window_from(host_dropin)
    # The component search path is asserted as strictly as the window, and the
    # rule is the one invariant this design turns on: the enrollment and the
    # refresh must read the SAME two trees, by their own paths, or one of them
    # computes a policy the other cannot satisfy. Measured both ways: a host-only
    # policy named PCR 0 = b3bd826a while the initrd's TPM held 1c17662
    # (Esys_PolicyOR, 0x1c4, recovery key), and a components path matching nothing
    # at all produced the PCR-15-only policy.
    #
    # Each side therefore names exactly two directories, in this order: a
    # per-machine tree (/var/lib/pcrlock.d, where the lock-* steps write) and a
    # shipped one (/usr/lib/pcrlock.d -- or the initrd's /sysusr/usr mount of the
    # same verified tree, since the initrd has no /usr/lib/pcrlock.d of its own).
    # The check is on the PAIR of trees, not on the literal strings.
    host_components = _components_list(host_dropin)
    if enrolled:
        enrollment_components = _components_list(unit)
        for who, got in (("the enrollment", enrollment_components),
                         ("the host", host_components)):
            if len(got) != 2:
                raise ConfigError(
                    "%s names %d --components= directories, expected two: a "
                    "per-machine tree and a shipped one" % (who, len(got))
                )
            per_machine, shipped = got
            if not per_machine.endswith("/var/lib/pcrlock.d"):
                raise ConfigError(
                    "%s's per-machine component tree is %r, not a /var/lib/pcrlock.d"
                    % (who, per_machine)
                )
            if "/usr/lib/pcrlock.d" not in shipped:
                raise ConfigError(
                    "%s's shipped component tree is %r, which contains no "
                    "/usr/lib/pcrlock.d; a components path that matches nothing "
                    "loads nothing, silently" % (who, shipped)
                )
        # And the PCR selection: 15 must be OUT, because nothing measures it in
        # the initrd and the host's machine-id measurement lands there after the
        # volume is open. Without --pcr= it stays in the default set, is
        # trivially "fully recognized" at zero, and the refresh is then stuck
        # against a value the host has moved past (TPM2_RC_PCR_CHANGED).
        for name, path in (("enrollment", unit), ("host", host_dropin)):
            if _pcrs_from(path) is None:
                raise ConfigError(
                    "%s does not restrict --pcr=; PCR 15 then stays in the "
                    "prediction at zero and the host cannot refresh it" % name
                )
    if enrolled and window and host_window and window != host_window:
        raise ConfigError(
            "pcrlock location windows disagree: the enrollment uses %r and the "
            "host's make-policy drop-in uses %r" % (window, host_window)
        )
    if enrolled and not window:
        raise ConfigError(
            "the enrollment runs make-policy with no --location=, so it defaults to "
            "760-:940- and every firmware component is skipped"
        )
    for other in (
        "systemd-pcrlock@.service.d/10-vngrd.conf",
        "systemd-sysupdate-notify-pcrlock@.service.d/10-vngrd.conf",
    ):
        found = _window_from(_host_unit(paths, other))
        if found and window and found != window:
            raise ConfigError("pcrlock location windows disagree for %s: %r vs %r" % (other, found, window))
    return window, enrolled


def _parse_definition(paths: Paths) -> list[int]:
    for line in _repart_definition(paths).read_text().splitlines():
        if line.startswith("TPM2PCRs="):
            return parse_scalars(line.split("=", 1)[1])
    return []


def _parse_phases(paths: Paths) -> tuple[str, ...]:
    wrapper = paths.image_src / "scripts" / "ukify"
    if not wrapper.is_file():
        return ()
    match = re.search(r'^PHASE\s*=\s*"([^"]+)"', wrapper.read_text(), re.MULTILINE)
    return (match.group(1),) if match else ()


def _parse_repart_sizes(paths: Paths) -> dict[str, str]:
    sizes: dict[str, str] = {}
    for conf in sorted((paths.image_src / "mkosi.repart").glob("*.conf")):
        sections = parse_ini(conf)
        label = sections.get("Partition", {}).get("Label", conf.stem)
        minimum = sections.get("Partition", {}).get("SizeMinBytes", "")
        sizes[label] = minimum
    return sizes


def _parse_repart_labels(paths: Paths) -> tuple[str, ...]:
    labels: list[str] = []
    for conf in sorted((paths.image_src / "mkosi.repart").glob("*.conf")):
        sections = parse_ini(conf)
        label = sections.get("Partition", {}).get("Label")
        if label:
            labels.append(label)
    return tuple(labels)
