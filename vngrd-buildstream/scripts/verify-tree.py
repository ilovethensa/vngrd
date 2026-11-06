#!/usr/bin/env python3
"""Check a generated base tree against vngrd's filesystem contract.

Fails loudly rather than returning a status, because every caller here is a
build script and the interesting failure is "the tree is subtly wrong", which a
bare nonzero exit would send you looking for somewhere else.
"""

import os
import re
import subprocess
import sys

INTERP = "/usr/lib/ld-linux-x86-64.so.2"

# Directories that must not exist at all, not even as symlinks. See AGENTS.md.
FORBIDDEN = ("bin", "sbin", "lib", "lib64")

# Paths that betray a build that escaped its sandbox.
LEAK_MARKERS = (b"/nix/store", b"/dest/usr/lib")

# Big files are skipped: scanning a few hundred MB of LLVM bitcode costs more
# than it is worth, and these markers are in metadata, not bulk data.
MAX_SCAN = 8 * 1024 * 1024


def regular_files(root):
    """Yield every regular file under root, skipping symlinks.

    Symlinks are skipped because os.stat would follow them and report the
    target's contents, filing the defect against the link instead of the file.
    """
    for dirpath, _dirs, names in os.walk(root):
        for name in names:
            path = os.path.join(dirpath, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            yield path


def interp_of(path):
    """Return the PT_INTERP of an ELF file, or None if it has none.

    readelf prints "  [     0]  /lib64/ld-linux-x86-64.so.2", so the offset
    bracket has to come off before the path can be read.
    """
    out = subprocess.run(
        ["readelf", "-p", ".interp", path], capture_output=True, text=True
    ).stdout
    match = re.search(r"\[\s*\d+\]\s*(\S+)", out)
    return match.group(1) if match else None


def check_top_level(root):
    problems = []
    for name in FORBIDDEN:
        if os.path.lexists(os.path.join(root, name)):
            problems.append(f"/{name} still present")
    if not os.path.exists(os.path.join(root, "usr/lib/ld-linux-x86-64.so.2")):
        problems.append("no /usr/lib/ld-linux-x86-64.so.2")
    return problems


def check_interp(root):
    """Every executable must run under the merged-/usr loader, or nothing boots."""
    problems = []
    count = 0
    bad = []
    for path in regular_files(os.path.join(root, "usr")):
        interp = interp_of(path)
        if interp is None:
            continue
        count += 1
        if interp != INTERP:
            bad.append(f"{os.path.relpath(path, root)}: {interp}")
    if bad:
        problems.append(f"{len(bad)} ELF files on the wrong interpreter, "
                        f"first: {bad[0]}")
    print(f"  {count} ELF files carry PT_INTERP, all {INTERP}")
    return problems


def check_runpath(root):
    """A few objects have a runpath; only a non-merged one is a problem.

    The value is tested as a whole rather than by substring. `/usr/lib/perl5/...`
    contains "/lib/" and is perfectly correct, while `/lib/...` is not, and the
    two differ only by what precedes the slash.
    """
    bad = []
    for path in regular_files(os.path.join(root, "usr")):
        out = subprocess.run(
            ["readelf", "-d", path], capture_output=True, text=True
        ).stdout
        for value in re.findall(r"Library (?:runpath|rpath): \[(.*)\]", out):
            for entry in value.split(":"):
                if entry.startswith(("/lib", "/usr/lib64", "/nix/")):
                    bad.append(f"{os.path.relpath(path, root)}: {entry}")
    if bad:
        return [f"{len(bad)} objects with a non-merged RPATH/RUNPATH, "
                f"first: {bad[0]}"]
    return []


def check_linkage(root):
    """Every NEEDED library in the tree must be resolvable in the tree.

    Worth its own check because the failure mode is indirect. The base is built
    with --nodeps, so a build tool can arrive without the library it links, and
    nothing notices until some unrelated package execs `sed` and gets
    "error while loading shared libraries". Checking the whole tree at once finds
    all of them in one pass instead of one per build.

    Resolution mirrors ld.so's search, minus the environment: the needing
    object's own directory ($ORIGIN, which is how glibc's gconv modules find
    their libJIS.so-style helpers beside them), then the runpath, then
    /usr/lib.
    """
    libdir = os.path.join(root, "usr/lib")
    missing = {}

    for path in regular_files(root):
        out = subprocess.run(
            ["readelf", "-d", path], capture_output=True, text=True
        ).stdout

        runpaths = []
        for value in re.findall(r"Library (?:runpath|rpath): \[(.*)\]", out):
            for entry in value.split(":"):
                # $ORIGIN (and $LIB, which expands to lib on every system
                # vngrd targets) are relative to the needing object, not to /.
                entry = entry.replace("$ORIGIN", os.path.dirname(path))
                entry = entry.replace("${ORIGIN}", os.path.dirname(path))
                entry = entry.replace("$LIB", "lib")
                runpaths.append(entry)

        def resolves(lib):
            if os.path.exists(os.path.join(os.path.dirname(path), lib)):
                return True
            if any(os.path.exists(os.path.join(d, lib)) for d in runpaths):
                return True
            return os.path.exists(os.path.join(libdir, lib))

        for lib in re.findall(r"Shared library: \[([^]]+)\]", out):
            # pcre2 names its charset modules like libJIS.so without a version;
            # they are dlopened by name and are not DT_NEEDED dependencies.
            if not lib.startswith("lib") or "." not in lib:
                continue
            if not resolves(lib):
                missing.setdefault(lib, []).append(
                    os.path.relpath(path, root))

    if missing:
        return [f"{len(missing)} unresolved libraries, "
                + "; ".join(f"{lib} (needed by {users[0]})"
                            for lib, users in sorted(missing.items()))]
    return []


def check_leaks(root):
    """No file may reference the build sandbox or a Nix store."""
    bad = []
    for path in regular_files(root):
        if os.path.getsize(path) > MAX_SCAN:
            continue
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError:
            continue
        if any(marker in data for marker in LEAK_MARKERS):
            bad.append(os.path.relpath(path, root))
    if bad:
        return [f"{len(bad)} files reference a build path, first: {bad[0]}"]
    return []


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <tree>", file=sys.stderr)
        return 2
    root = sys.argv[1]

    problems = check_top_level(root)
    if problems:
        print("tree does not satisfy the vngrd contract:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    problems = (check_interp(root) + check_runpath(root)
                + check_linkage(root) + check_leaks(root))
    if problems:
        print("tree does not satisfy the vngrd contract:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1

    print("  ok: merged-/usr, every PT_INTERP rewritten, every NEEDED library "
          "present, no build-host paths")
    return 0


if __name__ == "__main__":
    sys.exit(main())