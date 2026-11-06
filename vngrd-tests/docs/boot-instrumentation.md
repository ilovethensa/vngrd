# Boot instrumentation contract

The suite observes a boot as a stream of structured events rather than by
scraping console prose. This document defines the contract and how the guest
half is installed.

## The line format

```
VNGRO <version> <event-name> [key=value ...]
```

- `VNGRO` is a literal prefix. The parser ignores every other line.
- `<version>` is the contract version, currently `1`. An unknown version is a
  parse error, not a silently ignored line, so the two halves cannot drift
  quietly.
- `<event-name>` is a dotted name the suite chose (`boot.usr-mounted`,
  `cryptsetup.failed`, `tpm.bound`).
- Fields are whitespace-separated `key=value`. A value may not contain
  whitespace; the reporter normalises spaces to `_`.

Examples:

```
VNGRO 1 boot.enter-initrd
VNGRO 1 boot.usr-mounted fs=erofs
VNGRO 1 boot.root-unsealed
VNGRO 1 assert id=etc-is-tmpfs ok=1 detail=tmpfs
VNGRO 1 boot.self-test-complete
```

## Event names in use

Milestones:

| Event | Emitted when |
|---|---|
| `boot.enter-initrd` | the initrd root filesystem target was reached |
| `boot.usr-mounted` | `/sysusr/usr` is mounted from verity |
| `boot.root-unsealed` | the LUKS2 root opened |
| `boot.switch-root` | the host took over |
| `boot.multi-user` | multi-user target reached |
| `boot.login-ready` | the getty prompt is up |
| `boot.emergency` | emergency mode was entered |
| `boot.self-test-complete` | the guest check list finished |

State and refusal events (`tpm.bound`, `tpm.absent`, `cryptsetup.start`,
`cryptsetup.failed`, `cryptsetup.unseal-failed`, `cryptsetup.no-signature`,
`verity.corrupt`, `sb.denied`, `lockdown.*`, `fixate.*`, ...) are defined by the
`VNGRO` lines the image emits; the fallback anchor table in `harness/guest.py`
carries the same names for the messages that are stable enough to bridge with.

`assert` events carry three fields: `id`, `ok` (`1`/`0`) and a single-token
`detail`.

## The guest programs

| Path | Role |
|---|---|
| `guest/vngrd-testreport` | writes the lines; no dependencies, POSIX sh |
| `guest/checks.tsv` | the guest-side checks, as data |
| `guest/units/*.service` | systemd units that call the reporter |
| `guest/install.sh` | copies the payload into a staged tree |

`checks.tsv` is tab separated:

```
id <TAB> mode <TAB> expected <TAB> command
```

`mode` is one of `eq` (stdout equals), `has` (stdout contains), `rc` (exit
status equals) or `absent` (the path in `expected` does not exist). Adding a
check is one line, not a new host-side case.

## Gating

Every unit carries `ConditionKernelCommandLine=vngrd.test=1`, so nothing runs on
a normal boot and the payload is inert in a shipped image. A test image is
produced by adding `vngrd.test=1` to the signed kernel command line.

Two options for building one:

1. **Sign a test UKI.** Add `vngrd.test=1` to the UKI's embedded command line and
   re-sign it. The suite already has the pieces for this (`harness/uki.py`
   strips the old certificate table and signs with `systemd-sbsign`); the
   unported `t4`/`t10` cases need the same path.
2. **Include the flag in the image under test** for a dedicated test build.

Option 1 keeps the shipped artefact untouched, which is why it is preferred.

## Installing into a tree

```sh
guest/install.sh output/rootfs   rootfs
guest/install.sh output/initrd-root initrd
```

Then rebuild the initrd and the UKI so the units and the reporter are actually
inside the booted system. Until that is done, boot cases use the anchor fallback
and `t15-etc-tmpfs` skips.

## Why not a guest agent

QEMU's `guest-exec`/`guest-file-read` need `qemu-guest-agent` in the guest, which
this minimal image does not ship. Events are therefore **guest-pushed** over the
existing console, which needs no new binary in the image and no network. A
virtio-serial agent is a possible future upgrade if richer queries are needed.
