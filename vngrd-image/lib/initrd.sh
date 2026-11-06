#!/bin/bash

build_initrd() {
    local ROOT=$HERE SRC=$ROOTFS
    local DST=$INITRD_ROOT
    local READELF=${READELF:-readelf}
    local queue="" seen="" p b l f d n ref

    [[ -d $SRC ]] || die "$SRC not found — build the rootfs first (vngrd-rootfs/scripts/publish.sh)"
    command -v "$READELF" >/dev/null 2>&1 || die "$READELF not found (binutils)"

    rm -rf "$DST"
    mkdir -p "$DST"

# Executables we take the DT_NEEDED closure of, plus the helpers that units name
# by bare name. The non-obvious ones:
#   systemd            PID 1
#   systemd-repart     creates the ext4 root on first boot
#   systemd-cryptsetup opens the LUKS2 root
#   mkfs.ext4          repart invokes it by name
#   mount, umount      systemd's built-in ExecStart=/ExecStop= for .mount units.
#                      No unit file mentions either, so nothing scanning the unit
#                      files finds them, and without mount every API VFS mount --
#                      including the verity /usr mount -- fails while the boot
#                      still looks healthy.
#   sulogin            the emergency shell's login prompt. Failed-boot path only,
#                      but it is 56K and without it even that shell will not start.
#   touch, flock       ExecStartPost of several oneshots; flock is the wrapper
#                      systemd-tmpfiles and systemd-sysusers are invoked through.
#   mkdir              the /etc/systemd/system confinement mount, below
#   mountpoint         ditto: its one line of output is the boot-log evidence that
#                      the bind actually landed, and a non-zero exit is a fail-closed
#                      check rather than a silent no-op
#   udevadm            /dev
# No shell: usr/bin/sh is a symlink to fish, so seeding it would add 12MB, and
# /bin/sh does not exist anywhere in a merged-/usr rootfs. The previous
# whole-rootfs initrd did not have one either and booted fine.
# No module machinery either. The kernel is CONFIG_MODULES=n, so there is no
# loader: modprobe could only fail and /proc/sys/kernel/modules_disabled is
# permanently 1. kmod used to be seeded because a bare name in a unit must
# resolve, and that reasoning does not apply to a capability the kernel lacks.
# The "no .ko anywhere" assertion below is what actually guarantees it, and it is
# the check to extend if that ever changes.
# usr/bin/tpm2, below, is the multicall binary: tpm2_nvdefine, tpm2_nvread,
# tpm2_nvwrite, tpm2_nvundefine and tpm2_eventlog are all relative symlinks to
# it, and tpm2-tools installs them that way. Seeding the five names without it
# leaves the dangling-symlink sweep deleting them, one note per tool, and the
# failure that surfaces is a missing tpm2 rather than a missing tool.
# Above the list, not inside it: these lists are word-split, so a `#` comment
# line inside one contributes a bare "#" as a seed.
# systemd-ask-password is seeded, and deliberately so: it is what
# systemd-cryptsetup execs when a keyslot needs a passphrase typed in, so it
# is the initrd's passphrase fallback -- the whole point of the keyslot that
# vngrd-provision.service enrols. A bare-name skip here would look like a
# tidy-up and would leave the fallback silently broken on the one boot that
# needed it, which is exactly the boot where a broken fallback is a brick.
# Directories and files copied verbatim, by path, before the DT_NEEDED closure walk.
# NOT usr/lib/repart.d: repart takes no --root= on the drop-in, sets arg_root=/sysusr
# itself when /sysusr/usr is a mount point (repart.c:10864-10881) and then chases
# repart.d against that root, so it reads /sysusr/usr/lib/repart.d/10-root.conf from
# the VERIFIED /usr. A copy here would be a second definition the verity hash does not
# cover, and it is worse than dead weight: it satisfies repart.service's
# ConditionDirectoryNotEmpty=|/usr/lib/repart.d, so the unit looks configured while
# repart is reading something else.
# NOT etc/crypttab: /etc is a tmpfs and the image ships no /etc payload, so that file
# lives at usr/share/factory/etc/crypttab and is copied into place explicitly below.
# NOT usr/lib/udev/rules.d/64-btrfs.rules: the root is ext4.
# usr/lib/vngrd carries vngrd-fixate-nvwrite. The generator comes along with
# usr/lib/systemd because systemd's SYSTEM_GENERATOR_DIR is inside it; this one
# has no such fixed home, it is ours, and it lives where build.sh put it.
# The comment is here and not inside the literal below for the same reason the
# backtick note further down gives: seed_tree is word-split, so a "#" inside it is
# not a comment, it is a path, and the build fails with the wonderfully clear
# "missing seed #".
    mapfile -t seed_tree < <(read_list "$HERE/initrd/seed-tree.txt")

# printf, cat, ls and sync are here because units exec them by absolute path and
# nothing links against them, so the closure walk cannot find them. That is not
# hypothetical: vngrd-provision.service execs /usr/bin/printf in an ExecStartPre,
# it was not seeded, and the unit failed before enrolling anything -- so the root
# passphrase was never created and the console showed only
#     Failed to start Enrol a root passphrase for the LUKS2 volume (once).
# with not one word of reason, because the missing binary is the exec. The same
# absence would break any future unit that prints a warning.
# systemd-pcrextend is the PCR 11 phase barrier of the boot, the
# binary behind systemd-pcrphase-initrd.service. It is what makes the root volume
# key available for the initrd and unavailable afterwards:
#     ExecStart  systemd-pcrextend --graceful enter-initrd
#     ExecStop   systemd-pcrextend --graceful leave-initrd
# Without it in the initrd the unit fails to start, enter-initrd is never
# measured, and PCR 11 stays at the bare stub-only value -- which is the value
# the signed .pcrsig does NOT cover, so the TPM never unseals the root at all.
# The failure would read as a cryptsetup failure with no TPM message, because
# the missing binary is not obviously related to unsealing.
# Its DT_NEEDED is libsystemd-shared-262.so (already pulled in by PID 1) and
# libc.so.6, so the closure walk covers it and no seed_lib entry is needed.
# This note is ABOVE the literal on purpose. Inside seed_bin="..." a "#" line is
# string content, not a comment, and a backtick in one is a LIVE command
# substitution -- an unbalanced one swallows the rest of the script and the
# failure surfaces hundreds of lines away, as
#     line 358: unexpected EOF while looking for a matching backquote
# which is how the build spent time on a bug that is three lines long here.
    mapfile -t seed_bin < <(read_list "$HERE/initrd/seed-bin.txt")

# Loaded with dlopen(), so nothing DT_NEEDEDs them and the closure walk would
# never reach them. Only the device TCTI is actually loaded: tpm2-device=auto
# leaves arg_tpm2_device NULL, so tpm2_context_new() falls back to the compiled-in
# "device:/dev/tpmrm0" (tpm2-util.c:692-696). The other nine are dead weight.
# These go through take(), not copy(), and that is not a style choice. They are
# symlink chains (libtss2-esys.so.0 -> libtss2-esys.so.0.0.1), so a plain cp -a
# reproduces the link without its target and the initrd fails at unseal time with
# "Failed to load libtss2-esys.so.0" -- which, because systemd-tpm2-setup-early
# runs with --graceful, shows up only as the cryptsetup unit failing much later
# with no obvious cause.
# libtss2-sys is .so.1, not .so.0: tpm2-tss 4.x bumped that soname, and the other
# five tss2 libraries keep .so.0. One wrong guess here is not caught until the
# initrd build, and the seed check then reports only the FIRST missing path.
# Above seed_lib=, not inside it, and that is deliberate: these lists are
# word-split, so a `#` comment line placed inside one contributes a bare "#" as a
# seed and the build dies with "missing seed #". The same trap is in
# scripts/01-build.sh's ORDER and is called out there.
    mapfile -t seed_lib < <(read_list "$HERE/initrd/seed-lib.txt")

# Directories and files copied verbatim.
# All of usr/lib/systemd, not just system/ and system-generators/. Two shipped
# versions got that wrong the same way, and both only showed up by booting:
#   1. seeding system/ does not bring system-generators/, which is a *sibling*
#      directory. Without the generators no cryptsetup, no verity, no /usr -- and
#      no error, just a boot that hangs with nothing on the console.
#   2. seeding system/ also does not bring the sibling *binaries* in that
#      directory, and PID 1 execs one of them by path: systemd-executor mounts
#      /proc, /sys, /dev and /run before anything else. Without it PID 1 dies
#      with "Failed to allocate manager object" and freezes.
# Neither is a DT_NEEDED edge, so the closure walk cannot find them. The initrd
# transaction reaches ~111 units from initrd.target/basic.target/sysinit.target
# plus whatever the generators synthesise, so picking units by hand would mean
# re-deriving systemd's own closure on every bump. Seeding the whole directory
# is 12M, of which the closure already accounts for 7M.
# Libraries the initrd's tools dlopen() BY SONAME at run time.
# Why this list exists and why a closure walk cannot do it: v262's
# libsystemd-shared-262.so has DT_NEEDED of libc and ld-linux only, and the
# cryptography and partitioning libraries are all loaded by name --
# dlopen_cryptsetup(), dlopen_libblkid(), dlopen_fdisk(), dlopen_libmount(),
# dlopen_libcrypto() (src/repart/repart.c:4794,7307,11726,6143 and
# src/veritysetup/veritysetup.c:513). readelf follows DT_NEEDED, so it walks
# straight past every one of them, and the initrd shipped with NO libcryptsetup
# and NO libfdisk in it at all.
# The symptom is silent and misattributes itself. run() in veritysetup.c and in
# repart.c both call log_setup() only AFTER parse_argv(), and the dlopen() runs
# after that, so a -ENOENT should be logged -- but what actually reached the
# console was:
#     systemd-veritysetup@usr.service: Main process exited, status=1/FAILURE
#     DEPEND  Dependency failed for Cryptography Setup for vngrd-root.
# and t6a-pcr7 and t6b-fresh-srk assert on that second line, so a missing
# library reported as the PCR 11 problem this whole design is about.
# Cannot simply seed the path either: in the rootfs usr/lib/libcryptsetup.so.12
# is a symlink to libcryptsetup.so.12.11.0, seeding the symlink brings no target,
# and the dangling-symlink sweep below deletes it again. So: follow the link to
# the real file, read its SONAME, install the real file under that name. No
# version is written down, so a library upgrade changes the output and not this
# script.
# WHICH ones are needed depends on which tools actually run in the initrd. All of
# these are: systemd-repart creates the LUKS2 root (cryptsetup, fdisk, blkid) and
# systemd-veritysetup and systemd-cryptsetup open it (cryptsetup, blkid). libmount
# is dlopen()ed at LOG_DEBUG so it is optional, but it is two files and a
# dependency of fdisk, so it is here rather than special-cased.
# Every library the initrd's tools dlopen() by soname.
# The five below are the ones the boot path cannot do without: libcryptsetup
# (systemd-veritysetup, systemd-cryptsetup, systemd-cryptenroll, repart all mark it
# 'required' in their .note.dlopen), libfdisk and libblkid (repart, required),
# libmount (PID 1 itself, required) and libcrypto.
# The four after them are 'recommended' or 'suggested', and their absence is
# SILENT, which is the reason they are here rather than left to a later boot to
# discover:
#   libseccomp.so.2  is_seccomp_available() returns false without it
#                    (src/shared/seccomp-util.c:312-332), and every
#                    SystemCallFilter=/SystemCallArchitectures=/
#                    RestrictAddressFamilies= in the initrd's units is then
#                    dropped at LOG_DEBUG (src/core/exec-invoke.c:1615-1636).
#                    udevd and journald both ship those, so the whole initrd
#                    loses its syscall filters and every unit still reports green.
#   libzstd.so.1     is DEFAULT_COMPRESSION for journald (build/config.h:61), but
#                    compression_supported_journal() is a COMPILE-time HAVE_ZSTD
#                    check, so journald only finds out at compress time and
#                    stores every entry uncompressed
#                    (src/libsystemd/sd-journal/journal-file.c:1864-1866).
#   liblzma.so.5     journald/coredump/journalctl compression.
#   libpcre2-8.so.0  only LogFilterPatterns= and journalctl --grep, neither of
#                    which any initrd unit uses. Included for completeness so the
#                    list is derived from the .note.dlopen set rather than from
#                    which failures happened to be noticed.
# Read the authoritative list out of the built binaries with
#   readelf -n <elf> | sed -n 's/^ *Dlopen Metadata: //p'
# (systemd-analyze dlopen-metadata does not work here: it is #if HAVE_ELFUTILS
# and this build has -Delfutils=disabled.) The consumer to copy is dracut's
# add_dlopen_features in modules.d/{11systemd-repart,11systemd-veritysetup,
# 71systemd-cryptsetup,11systemd-udevd,11systemd-journald}/module-setup.sh.
for _soname_want in libcryptsetup libblkid libfdisk libmount libcrypto \
                    libseccomp libzstd liblzma libpcre2; do
    # Resolve the real file. The dev symlink (<name>.so) is what is usually
    # installed and it is the shortest path to the target, but not always: pcre2
    # ships libpcre2-8.so.0 with no libpcre2.so symlink at all, and its SONAME is
    # libpcre2-8.so.0, not libpcre2.so.1 as the name would suggest. So fall back
    # to <name>.so.* and let the SONAME decide the final installed name, which is
    # what dlopen() will actually be asked for.
    _link=""
    for _cand in "$SRC/usr/lib/${_soname_want}.so" \
                 "$SRC/usr/lib/${_soname_want}.so."* \
                 "$SRC/usr/lib/${_soname_want}-8.so"* \
                 "$SRC/usr/lib/${_soname_want}-2.so"*; do
        if [ -f "$_cand" ]; then _link=$(readlink -f "$_cand"); break; fi
    done
    if [ -z "$_link" ] || [ ! -f "$_link" ]; then
        die "$_soname_want is missing under $SRC -- the initrd's repart, veritysetup and cryptsetup all dlopen() it by soname, and without it the root volume is never created and /usr is never verified"
    fi
    # No `exit` in the awk: this pipeline runs under build.sh's `set -o
    # pipefail`, and a consumer that exits after its first line leaves the
    # producer writing to a closed pipe. objdump then dies of SIGPIPE and
    # pipefail reports the pipeline as failed (141) -- a race that fires when
    # awk's exit lands before objdump's last write, which it did for every
    # build after a certain library size. Printing every SONAME and taking the
    # last drains the input instead, so objdump always finishes.
    _soname=$(objdump -p "$_link" 2>/dev/null | awk '$1 == "SONAME" { print $2 }' | tail -n 1)
    [ -n "$_soname" ] || die "$_soname_want has no SONAME: objdump -p on $_link printed none"
    mkdir -p "$DST/usr/lib"
    install -m 0755 "$_link" "$DST/usr/lib/$_soname"
    [ -f "$DST/usr/lib/$_soname" ] || die "$_soname did not land in the initrd"
    note "seeded $_soname (from $(basename "$_link")): dlopen()ed by soname, invisible to the DT_NEEDED walk"
done

# And the closure those libraries themselves need, which is only reachable now
# that they are in the tree. libdevmapper in particular is what talks to
# /dev/mapper/control -- without it crypt_attach cannot create the verity or LUKS2
# device, so every unlock in the initrd fails.
for _l in libuuid.so.1 libdevmapper.so.1.02 libjson-c.so.5; do
    _f=$(find "$SRC/usr/lib" -name "$_l*" -print -quit 2>/dev/null || true)
    [ -n "$_f" ] || die "libcryptsetup needs $_l but it is not in the rootfs"
    install -m 0755 "$_f" "$DST/usr/lib/$_l"
done
note "seeded the closure of the above: libuuid, libdevmapper, libjson-c"

# The crypttab is copied in below, not seeded. /etc is a tmpfs (the initrd
# mounts one over /sysroot/etc before switch_root), so the image ships no /etc
# payload at all and the file this seed used to copy is gone. The initrd still
# needs a crypttab of its own -- the one that gates the unlock is read in the
# initrd, from the initrd's /etc, which is the UKI's own (see line 18) -- and
# that UKI is signed, so the crypttab inside it is authenticated. The factory
# path is where the content now lives, and it is inside the verity'd /usr.
# Two files, one content, and the copy that matters is the signed one.
# usr/lib/libcryptsetup.so.12 is seeded EXPLICITLY and cannot be found by the
# closure walk. v262's libsystemd-shared-262.so has DT_NEEDED of libc and
# ld-linux only: libcryptsetup is dlopen()ed at runtime by
# dlopen_cryptsetup() (src/veritysetup/veritysetup.c:513, and the same call
# in src/cryptsetup/cryptsetup.c), not linked. readelf walks DT_NEEDED, so
# it walks straight past a library that is loaded by name at run time, and
# the initrd shipped with NO libcryptsetup in it at all.
# The soname is the .so.NN of the built library, not a fixed .so.1 -- this is
# cryptsetup 2.8.8, whose SONAME is libcryptsetup.so.12, and the seeded
# name is asserted below against the real file so a cryptsetup upgrade
# fails the build rather than the first boot.
# The failure it caused was silent. run() in veritysetup.c calls log_setup()
# only AFTER parse_argv(), and dlopen_cryptsetup() runs after that, so the
# -ENOENT should have been logged -- but the symptom seen was
# `systemd-veritysetup@usr.service: Main process exited, status=1/FAILURE'
# with nothing on the console, and the root volume failing on the
# dependency, which t6a-pcr7 and t6b-fresh-srk report as a PCR 11 fault.
# KNOWN NOT TO WORK, recorded rather than claimed: verified against the initrd
# inside a built UKI, all four are still present and the loop below's
# "excluded <path>" note is a lie. Unresolved, and the most likely cause is that
# mkosi populates the initrd's usr/lib/systemd from more than SkeletonTrees, so
# removing a path from the skeleton does not remove it from the initrd (the
# shipped initrd tracks the skeleton's 461 entries down to 447 — clearly a source,
# evidently not the only one). The cheap next step is a marker file:
#   touch ../output/initrd-root/usr/lib/systemd/.mkosi-probe
#   mkosi build --force && cpio -t <the initrd> | grep .mkosi-probe
# Until that is settled, do not cite this list as the reason a library is absent
# from the initrd — cite DT_NEEDED and the closure walk, which is what decides.
# systemd-import and systemd-export are referenced by systemd-sysupdate
# (50-usr.transfer runs `systemd-import raw') and by systemd-importd, but both
# are host side: sysupdate only runs from vngrd-sysupdate.service after
# switch_root, and importd's socket does not exist in the initrd.
    mapfile -t exclude_bin < <(read_list "$HERE/initrd/exclude-bin.txt")

# Two rules.d files are ours and are not optional:
#   10-dm.rules creates /dev/mapper/*. libdm and libcryptsetup are built
#     --disable-udev, and mkosi's own initrd drop-in only sets OPTIONS+="db_persist",
#     so nothing else makes /dev/mapper/usr or /dev/mapper/vngrd-root appear and
#     the device units time out with no console output at all.
#   60-persistent-storage.rules creates /dev/disk/by-partlabel (crypttab) and
#     /dev/disk/by-partuuid (usrhash=); 99-systemd.rules puts TAG+="systemd" on
#     devices so the .device units can be satisfied.


copy() {
    local p; for p in "$@"; do
        [ -e "$SRC/$p" ] || die "missing seed $p in $SRC"
        mkdir -p "$DST/$(dirname "$p")"
        if [ -d "$SRC/$p" ]; then
            # Copy the contents, not the directory: `cp -a src dst' nests when dst
            # already exists, which it does for usr/lib/systemd (the closure walk
            # has created it to hold libsystemd-{core,shared}-257.so, and
            # usr/lib/systemd/systemd is a seed *binary* inside it). "src/."
            # merges instead, and is a no-op on the files already there.
            mkdir -p "$DST/$p"
            cp -a "$SRC/$p/." "$DST/$p/"
        else
            cp -a "$SRC/$p" "$DST/$p"
        fi
    done
}

# Breadth-first over DT_NEEDED, following RUNPATH then RPATH then the default
# dirs. Both matter here and not in theory:
#   - systemd, systemd-repart and the other systemd binaries carry
#     RUNPATH=/usr/lib/systemd, so their two shared objects live in
#     usr/lib/systemd/ and not in usr/lib/. A resolver that only searches the
#     default dirs cannot find libsystemd-core-257.so.
#   - mkfs.ext4 carries RUNPATH=/out/usr/lib:..., left over from the package
#     build's --sysroot. That path does not exist in the image, so the search has
#     to fall through it rather than treat it as fatal.
# Each library is copied to the *same* path relative to the source root that it
# occupies there, so the loader's search order in the initrd is identical to the
# loader's search order on the host. Flattening everything into usr/lib/ would
# work today and would break the moment a RUNPATH stopped being redundant.

# find_lib <needed-name> <referring-elf> — where the referrer would find it.
find_lib() {
    local n=$1 ref=$2 d
    for d in $("$READELF" -d "$ref" 2>/dev/null | sed -n \
                  -e 's/.*(RUNPATH).*\[\(.*\)\]$/\1/p' \
                  -e 's/.*(RPATH).*\[\(.*\)\]$/\1/p' | tr ':' ' '); do
        if [ -e "$SRC$d/$n" ]; then
            printf '%s\n' "$SRC$d/$n"
            return 0
        fi
    done
    for d in /usr/lib /usr/lib64 /lib; do
        if [ -e "$SRC$d/$n" ]; then
            printf '%s\n' "$SRC$d/$n"
            return 0
        fi
    done
    return 1
}

# take <abs-src-path> — copy one file into the tree and queue it for scanning.
take() {
    local f=$1 rel
    rel="${f#"$SRC"}"
    mkdir -p "$DST/$(dirname "$rel")"
    cp -aL "$f" "$DST/$rel"
    queue="$queue $f"
}

seen=""
queue=""

# The dynamic loader is the ELF interpreter, never DT_NEEDED. Copy it
# explicitly, since everything dynamically linked needs it.
ldso=""
for c in "$SRC/usr/lib/ld-linux-x86-64.so.2" "$SRC/lib/ld-linux-x86-64.so.2"; do
    if [ -e "$c" ]; then
        ldso="$c"
        break
    fi
done
[ -n "$ldso" ] || die "no dynamic loader found in $SRC"
take "$ldso"

# take(), not just "add to the queue". A dlopen'd library is referenced by
# nothing's DT_NEEDED, so the walk would scan it for its own dependencies and
# then never copy the thing itself -- which is how the first version of this
# script produced an initrd with libtss2-sys.so.1 and libtss2-mu.so.0 (both
# needed by something) but without libtss2-esys.so.0 (needed by nothing, being
# the entry point systemd dlopens). The symptom would be a root that cannot
# unseal, with systemd-tpm2-setup-early --graceful reporting success.
for l in "${seed_lib[@]}"; do
    [ -e "$SRC/$l" ] || die "missing seed $l"
    take "$SRC/$l"
done
for b in "${seed_bin[@]}"; do
    [ -e "$SRC/$b" ] || die "missing seed $b"
    queue="$queue $SRC/$b"
done

while [ -n "$queue" ]; do
    set -- $queue
    queue=""
    # Collect this round's DT_NEEDED *together with the ELF that referenced it*:
    # the search path is the referrer's RUNPATH, so resolving against an arbitrary
    # member of the queue is wrong (and fails on the very first library, because
    # the head of the queue is the loader, which has no RUNPATH at all).
    for ref in "$@"; do
        "$READELF" -d "$ref" 2>/dev/null |
            sed -n "s|^.*(NEEDED).*\[\(.*\)\]$|$ref\t\1|p"
    done | sort -u -k2,2 > "$DST/.needed"

    while IFS="$(printf '\t')" read -r ref n; do
        [ -n "$n" ] || continue
        case " $seen " in
            *" $n "*) continue ;;
        esac
        seen="$seen $n"
        case "$n" in
            ld-linux*|ld64*|ld-musl*) continue ;;
        esac
        f=$(find_lib "$n" "$ref") ||
            die "cannot locate library $n (needed by ${ref#"$SRC"})"
        take "$f"
    done < "$DST/.needed"
    rm -f "$DST/.needed"
done


copy "${seed_bin[@]}"
# Asserted, not assumed: this list is consumed below, and the script does `rm -rf
# "$DST"` near the top, so an assignment that goes missing takes the previous good
# initrd with it and then dies on an unbound variable under set -eu. That exact
# sequence happened once here, and the build error does not say which list was lost.
[ -n "${seed_tree:-}" ] || die "seed_tree is empty or unset but is copied below"
[ -n "${seed_bin:-}" ]  || die "seed_bin is empty or unset but is copied below"
[ -n "${seed_lib:-}" ]  || die "seed_lib is empty or unset but is walked below"

copy "${seed_tree[@]}"

for p in "${exclude_bin[@]}"; do
    if [ -e "$DST/$p" ]; then
        rm -f "$DST/$p"
        note "excluded $p (not used before the root filesystem exists)"
    fi
done

# The kernel is CONFIG_MODULES=n, so modprobe cannot do anything here. The
# on-disk usr/lib/systemd/system/modprobe@.service comes in with the
# usr/lib/systemd tree seed and execs the real /usr/bin/modprobe, which this tree
# does not have, so it is dropped and replaced at the higher-precedence
# /etc/systemd/system path.
# The replacement cannot be a bare no-op, and that is the whole bug. Every unit
# that wants a module loaded pins itself *before* sysinit.target and then waits
# for the template:
#   sys-kernel-config.mount        DefaultDependencies=no
#                                  Before=sysinit.target
#                                  Requires=/After=modprobe@configfs.service
#   sys-fs-fuse-connections.mount   same shape, modprobe@fuse.service
#   systemd-pstore.service          Before=sysinit.target
#                                   Wants=/After=modprobe@efi_pstore.service
#   systemd-repart.service          After=modprobe@loop.service modprobe@dm_mod.service
# A .service that does not say DefaultDependencies=no is handed the service
# defaults (src/core/service.c:748 service_add_default_dependencies, system
# manager): Requires=sysinit.target, After=sysinit.target and After=basic.target.
# Those two After= are the problem, and only because basic.target is itself
# After=sysinit.target, so a template instance ends up ordered after sysinit.target
# while the units that want it insist on running before it:
#   sysinit.target -> basic.target -> modprobe@configfs.service
#                   -> sys-kernel-config.mount -> sysinit.target
# Upstream's template does not have this problem because it opts out of the
# defaults (DefaultDependencies=no) and pins itself before sysinit.target, which
# is the slot the early-boot graph was drawn around. So the [Unit] section below
# is upstream's verbatim and only [Service] is replaced by the no-op; the ordering
# is not a stylistic choice, it is the part that has to stay in step with the
# units that reference the template. A condition is not an alternative: a unit
# whose condition fails is skipped but still participates in the ordering graph,
# so the edges are identical either way.
# Overriding the template is also the only way to keep the Wants=/After=/Requires=
# references working, which is the other half of why this file exists at all.
# systemd.unit(5) is explicit that a dependency list cannot be reset to empty, so
# dropping a Wants= means replacing the unit that declares it; and the unit cannot
# simply be deleted. Wants= on a unit that cannot be loaded is skipped
# (transaction.c:1043 -- -ENOENT is explicitly not an error for a Wants), but
# Requires= is not: sys-fs-fuse-connections.mount and sys-kernel-config.mount are
# Wanted by sysinit.target and hard-require this template, so with no template on
# disk at all transaction_add_job_and_dependencies() fails and the initrd
# transaction never starts. A unit that starts and does nothing satisfies both.
# The failure mode when the ordering above is dropped is not a build error and
# not a failed boot. The initrd still assembles, still passes every assertion in
# this script, and boots -- it just finds one of the cycles above on some
# fraction of boots, and PID 1 breaks it the way it always does:
# transaction_verify_order_one() walks back from the job the cycle closes on and
# deletes the first one that does not matter to the anchor (transaction.c:406).
# Which job that is depends on the order units happened to load in, so it varies
# between boots: deleting the cryptsetup job leaves the root volume locked and the
# machine in emergency mode, and deleting modprobe@dm_mod's or a mount's just
# silently drops that one piece of early boot. The only trace is one
# "Found ordering cycle" stanza in the boot log.
rm -f "$DST/usr/lib/systemd/system/modprobe@.service"
note "dropped the module-loader template; /etc override takes its place"
mkdir -p "$DST/etc/systemd/system"

# Initrd logging goes to the console.
# Without this, a failure in the initrd is completely silent. systemd-cryptsetup
# does log it -- "Current policy digest does not match stored policy digest",
# "TPM policy does not match current system state", "Failed to unseal secret using
# TPM2" -- but through systemd's logger into the initrd's volatile journal, which is
# gone before anyone can log in and which nothing in the serial-only harness can
# read. A unit's StandardOutput=journal+console does not help: that covers the
# process's own file descriptors, not systemd's logging.
# LogLevel is left at info, which is the default. debug was needed to find the
# above and is far too noisy to ship -- it prints every unit_file_build_name_map
# and every job transition.
# LogTarget= is a [Manager] setting and is NOT parsed from the kernel command line
# in v262; only a handful of options are (systemd.unit, dump_core and a few
# others), and the rd. prefix only filters those, so `rd.systemd.log_target=' was
# tried first and does nothing. It has to come from here.
cat > "$DST/etc/systemd/system.conf" <<'EOF'
[Manager]
LogTarget=console
EOF

cat > "$DST/etc/systemd/system/modprobe@.service" <<'EOF'
# Upstream's [Unit] section verbatim; see the seed lists under initrd/. Only [Service]
# differs, because there is no /usr/bin/modprobe in this tree to exec.
#
# DefaultDependencies=no and Before=sysinit.target are load-bearing, not
# decoration. Without them systemd's service defaults (src/core/service.c:748)
# add After=sysinit.target and After=basic.target to every instance, which cycles
# against each unit that does Before=sysinit.target while requiring this template
# -- sys-kernel-config.mount, sys-fs-fuse-connections.mount, systemd-pstore.service
# and systemd-repart.service. PID 1 breaks that cycle by deleting a job, and on
# some boots the job it deletes is the one that unlocks the root.
[Unit]
Description=Load Kernel Module %i (skipped: this kernel has no module loader)
DefaultDependencies=no
Before=sysinit.target
Documentation=man:modprobe(8)
ConditionCapability=CAP_SYS_MODULE
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/bin/touch /dev/null
RemainAfterExit=yes
EOF

# This is the one exclusion here that is not about size, and getting it wrong
# breaks the running system rather than the build.
# systemd-tmpfiles-setup.service and systemd-sysusers.service are oneshots with
# RemainAfterExit=yes AND RefuseManualStop=yes AND Conflicts=initrd-switch-root.
# So in the initrd they run, find no configuration (usr/lib/tmpfiles.d and
# usr/lib/sysusers.d are both asserted absent above), do nothing, and are left
# `active (exited)'. The Conflicts= stop that switch-root triggers is *refused*,
# because RefuseManualStop=yes does not exempt a conflict-driven stop. After
# switch-root PID 1 therefore sees the unit already active, and being pulled in
# only by Wants= from sysinit.target it is never queued again. The host's
# /usr/lib/tmpfiles.d and /usr/lib/sysusers.d are consequently never applied, and
# the writable root -- an empty LUKS2+btrfs filesystem that repart creates with no
# contents at all -- never gets an /etc.
# The visible symptom is not a boot failure, which is why it survived: the
# machine reaches a login prompt and most other assertions still pass. It is
# /etc/os-release that never appears, so vngrd-boot-gate.fish check 3 fails, so
# systemd-bless-boot never strips the boot counter off the slot, so after
# TriesLeft (3) boots sd-boot falls back to the empty _empty slot and the machine
# lands in emergency mode. /etc/shadow is missing too, so no login ever succeeds.
# The fix is a ConditionPathExists, NOT removing the units. Deleting them was
# tried first and it breaks the initrd: systemd-tmpfiles-setup.service carries
# `Before=sysinit.target' and a great many sysinit units carry a matching
# `After=', so deleting the file drops an ordering edge from the transaction
# graph. That is enough to make sysinit.target report
#   Found ordering cycle on cryptsetup.target/start
#     -> systemd-cryptsetup@vngrd\x2droot.service -> systemd-repart.service
#     -> modprobe@dm_mod.service -> basic.target -> sysinit.target
# on a fraction of boots, and the cryptsetup job that gets deleted to break the
# cycle is the one that opens the root. The image then never mounts at all.
# A condition-failed unit is left inactive rather than active, so the host's
# sysinit.target queues it for real, and every dependency edge in the graph stays
# exactly where it was. /etc/initrd-release exists only in the initrd, so the
# condition is false there and true on the host.
for u in systemd-tmpfiles-setup systemd-sysusers; do
    mkdir -p "$DST/etc/systemd/system/$u.service.d"
    cat > "$DST/etc/systemd/system/$u.service.d/10-initrd.conf" <<EOF
# Initrd-only drop-in; see the seed lists under initrd/.
#
# /etc/initrd-release exists only inside the initrd, so this is false there and
# true on the host. False in the initrd means the unit is skipped, not run, so it
# is left inactive instead of active (exited) -- which is what stops
# RemainAfterExit=yes + RefuseManualStop=yes from suppressing the host's run.
#
# A .service.d/ DIRECTORY, not /etc/systemd/system/$u.service. A same-named file
# in /etc/systemd/system does not merge, it REPLACES: the unit would then be these
# six lines with no Type=, no ExecStart= and none of the vendor ordering, systemd
# would refuse to load it ("Service has no ExecStart=... Refusing"), and every
# edge the rest of the transaction relies on would silently disappear. Only a
# drop-in directory keeps the vendor unit and layers on top of it.
[Unit]
ConditionPathExists=!/etc/initrd-release
EOF
    note "gated $u.service to the host: the initrd has no configuration for it, and running it here would leave it active (exited) and suppress the host's own run"
done

# systemd-journalctl.socket is the same initrd problem for a different reason.
# Its SocketGroup=systemd-journal is created by systemd-sysusers from
# usr/lib/sysusers.d/systemd-journal.conf, and the initrd seeds neither
# sysusers.d nor anything that runs sysusers (the gate above), so the group does
# not exist there and the socket cannot bind:
#   systemd-journalctl.socket: Failed to resolve group 'systemd-journal': Unknown group
#   [FAILED] Failed to listen on Journal Log Access Socket.
# The socket serves journalctl over varlink, which the initrd has no use for, so
# it is gated to the host the same way. On the host sysusers creates the group
# and the socket comes up.
u=systemd-journalctl.socket
mkdir -p "$DST/etc/systemd/system/$u.d"
cat > "$DST/etc/systemd/system/$u.d/10-initrd.conf" <<EOF
# Initrd-only drop-in; see the seed lists under initrd/.
#
# The systemd-journal group this socket binds to is made by sysusers, which the
# initrd does not run, so here it would only fail. /etc/initrd-release exists
# only in the initrd.
[Unit]
ConditionPathExists=!/etc/initrd-release
EOF
note "gated $u to the host: the systemd-journal group it binds to is created by sysusers, which the initrd does not run"

# The gap this closes. /usr is dm-verity'd and its root hash is inside a Secure
# Boot-signed UKI, but the root filesystem is a plain LUKS2+btrfs volume with no
# verity and /etc is an ordinary directory on it. /etc/systemd/system is the FIRST
# entry in the manager's unit search path, so a root on the writable layer writes a
# unit there and PID 1 loads it at the next boot, before the login prompt, while
# /usr still verifies perfectly and dm-verity says nothing. lockdown=integrity
# cannot help: it polices kernel interfaces (module load, bpf, kexec, /dev/mem,
# firmware, EFI vars) and unit loading is userspace.
# What is here is a read-only bind mount of /sysroot/usr/lib/vngrd/unit-search-path
# -- an empty directory inside the verified, erofs-backed /usr -- onto
# /sysroot/etc/systemd/system. The writable directory underneath is left exactly
# where it is on the btrfs root; anything a root planted there is simply no longer
# reachable through this path. /etc is NOT confined: only one directory is, and
# tmpfiles-setup has to keep being able to populate the rest of /etc (and it runs
# on the host, after this mount, so it would hit EROFS if /etc itself were read-only).
# Why the initrd, and why initrd-switch-root.service specifically. Three properties
# fall out of the placement, and all three are required:
#   1. BEFORE the host's PID 1 builds its transaction. This is the one that
#      systemd-confext cannot have, and it is why confext is not used here even
#      though upstream ships it. manager_startup() runs the generators, enumerates
#      unit files and coldplugs the initial transaction (src/core/manager.c:2080,
#      :2105, :2174) and only *then* does the event loop start running units.
#      systemd-confext.service is a .service: it is a job *in* the transaction it
#      would have to precede, and the unit files it is meant to hide have already
#      been read. unit_load_dropin() -- which is what follows
#      /etc/systemd/system/*.wants/ -- runs from unit_load() inside
#      manager_dispatch_load_queue(), i.e. still inside manager_startup()
#      (src/core/load-dropin.c:92, src/core/unit.c:1663, src/core/manager.c:2408).
#      So the merge lands after the attacker's unit and its enablement symlink are
#      both in the transaction. Doing it here, before the pivot, is what makes it
#      early enough. (A generator is the only thing that runs earlier, and
#      manager_run_generators() forks with FORK_NEW_MOUNTNS and remounts / read-only
#      for the child, so a mount made there dies with that namespace -- see
#      manager_execute_generators(), remount_ro=true.)
#   2. IN the mount namespace that becomes the host's. The initrd's PID 1 *is* the
#      host's PID 1: systemd-switch-root(1) pivots with mount(".", "/", MS_MOVE),
#      which carries every submount of the old root into the new one. So the bind
#      is in place before the host's PID 1 has executed a single instruction, and
#      no unit has to arrange, order or preserve anything afterwards.
#   3. AFTER /sysroot and /sysroot/usr are mounted. This is free rather than
#      arranged: initrd-switch-root.target carries
#      `After=initrd-root-fs.target initrd-fs.target' and `Before=initrd-switch-root.service',
#      so the service -- where these ExecStartPre= lines live -- cannot start until
#      both of those are up. The Requires=/After= below are belt and braces for the
#      one that is NOT in that chain (initrd-usr-fs.target, the verity /usr mount),
#      because a bind whose source does not exist would otherwise be a silent
#      downgrade: mkdir -p would create the source directory on the btrfs root and
#      the machine would come up "confined" to a writable copy of itself.
# A .service.d/ drop-in, not /etc/systemd/system/initrd-switch-root.service: a
# same-named file REPLACES the vendor unit instead of layering on it, and this
# unit has ExecStart=systemctl --no-block switch-root, DefaultDependencies=no,
# Wants=initrd-switch-root.target and OnFailure=emergency.target, none of which
# this file would carry. It is also Type=oneshot, which is what makes several
# ExecStartPre= legal.
# On a factory image /sysroot/etc does not exist at all -- repart creates an empty
# btrfs root and systemd-tmpfiles-setup creates /etc, on the host, after the
# pivot. That is fine, and it is also why the mkdir cannot be left to tmpfiles:
# tmpfiles runs on the host, i.e. after the transaction this mount has to precede,
# so a /etc/systemd/system it created would arrive too late to be of any use.
# Creating an empty /etc early is otherwise inert: no tmpfiles rule removes it, and
# every rule that populates it (L+ /etc/os-release, C! /etc/shadow, L /etc/pam.d)
# is create-if-absent, so they all behave exactly as they do on a btrfs root that
# was already there.
# --no-canonicalize on the bind: util-linux resolves symlinks in the mount target
# before handing it to the kernel, so an attacker who replaced /etc/systemd with a
# symlink would otherwise get us to bind the read-only directory onto whatever it
# points at. Taken literally, the kernel's MS_BIND on a symlink is ENOTDIR, which
# fails the unit, and initrd-switch-root.service has OnFailure=emergency.target.
# Fail closed.
mkdir -p "$DST/etc/systemd/system/initrd-switch-root.service.d"
TMPFS_DROPIN="$DST/etc/systemd/system/initrd-switch-root.service.d/10-vngrd-etc.conf"
cat > "$TMPFS_DROPIN" <<'EOF'
# Initrd-only drop-in; see the seed lists under initrd/. Nothing on the host carries it:
# the mount it makes is already in place by the time the host's PID 1 exists, so
# there is deliberately no host-side unit that re-establishes, re-checks or could
# be tricked into dropping it.
[Unit]
Description=Mount a fresh tmpfs over /etc before switch_root
Requires=initrd-usr-fs.target sysroot.mount
After=initrd-usr-fs.target sysroot.mount
# The two asserts, and they are the point of this unit. An assert cannot be
# masked from here -- it is evaluated before any ExecStartPre runs.
#
# Without the verity /usr the source path below does not exist, and the unit
# would otherwise mount an EMPTY tmpfs over /etc and boot a machine with no
# configuration at all, which fails later and less clearly.
AssertPathExists=/sysroot/usr/share/factory/etc
# Without the root, there is nothing to mount on.
AssertPathExists=/sysroot

[Service]
StandardOutput=journal+console
StandardError=journal+console
# mkdir first, so there is a mount target on a factory image where /etc does not
# exist. It has to be a real directory: a symlink here would be the attack the
# --no-canonicalize reasoning below used to refuse.
ExecStartPre=/usr/bin/mkdir -p /sysroot/etc
# THE CHANGE. /etc used to be a real directory on the LUKS2 root, which made it
# the highest-precedence writable surface in the image: root could drop a unit in
# /etc/systemd/system and PID 1 would load it at the next boot, with /usr still
# verifying perfectly and dm-verity reporting nothing. A tmpfs removes the
# surface rather than hiding the one directory that mattered.
#
#   --no-canonicalize: util-linux resolves symlinks in the mount SOURCE before
#   handing it to the kernel, so without it a replaced /etc would be followed
#   somewhere else. Taken literally, the kernel's mount() on a symlink is ENOTDIR,
#   which fails the unit, and initrd-switch-root.service has
#   OnFailure=emergency.target. Fail closed.
#
#   size= bounds a tmpfs against a hostile or buggy writer filling RAM. 16M is
#   ~2 orders of magnitude more than the factory tree (6 files, a few KB), so it
#   is a backstop and not a constraint.
#
#   noexec is safe here and worth having: nothing in this image executes anything
#   out of /etc. glibc's ld.so.cache is opened O_RDONLY and mmapped PROT_READ, so
#   it is unaffected by noexec -- and under this design /etc/ld.so.cache is gone
#   anyway, because the tmpfs is empty and no tmpfiles line creates one. glibc
#   falls back to a directory search, which is slower and not incorrect.
#
#   NOT nodev-excluded deliberately: nodev IS set, because /etc must never hold
#   a device node. It is set, not omitted.
ExecStartPre=/usr/bin/mount --no-canonicalize -t tmpfs -o mode=0755,size=16M,nosuid,nodev,noexec tmpfs /sysroot/etc
# The self-check, and the one line of boot-log evidence that the tmpfs landed.
# mountpoint(1) exits 1 when the path is not a mount point, so this is not a
# print that can be right by accident: if the mount silently did nothing, the
# unit fails and the boot does not continue into a PID 1 whose /etc is the
# writable root we just replaced.
ExecStartPre=/usr/bin/mountpoint /sysroot/etc
# systemd's PID 1 calls machine_id_setup() during startup, BEFORE
# systemd-tmpfiles-setup.service runs. So the host-side
# `L /etc/machine-id -> /var/lib/machine-id' rule in tmpfiles.d/10-vngrd-etc.conf
# creates the symlink too late: PID 1 has already seen an empty /etc, declared
# the boot a first boot, generated a throwaway ID into the tmpfs, re-run
# `systemd-preset-all' over the whole unit set, and re-created every
# /etc/systemd/system/*.wants symlink. That cost ~3s of every boot and gave the
# machine a different identity each time.
#
# The symlink therefore has to exist before switch_root, and its target has to
# exist too -- an empty file is enough. machine_id_setup() chases
# /etc/machine-id with CHASE_MUST_BE_REGULAR, follows the symlink, pins the
# target inode and writes the generated ID through it
# (src/shared/machine-id-setup.c), so /var ends up holding the one copy. Its own
# error message names "exists and is empty" as the bootstrap case.
#
# Order matters: these run after the mountpoint self-check, so a tmpfs that
# silently failed to land aborts the unit before the symlink is made.
ExecStartPre=/usr/bin/mkdir -p /sysroot/var/lib
ExecStartPre=/usr/bin/touch /sysroot/var/lib/machine-id
ExecStartPre=/usr/bin/ln -sfn /var/lib/machine-id /sysroot/etc/machine-id
EOF
note "added initrd-switch-root.service.d/10-vngrd-etc.conf: tmpfs over /etc before switch_root"



# The /etc tmpfs drop-in. Asserted line by line, because every one of these is a
# silent failure rather than a build error: the initrd assembles, the mount is
# skipped or misdirected, and the machine boots to a login prompt whose /etc is
# still the writable LUKS2 root we replaced, with no message anywhere. A red
# FAILED line that means nothing is worse than no line, because it is what a
# real regression looks like and so would be the one nobody believes.
for line in \
    'Requires=initrd-usr-fs.target sysroot.mount' \
    'After=initrd-usr-fs.target sysroot.mount' \
    'AssertPathExists=/sysroot/usr/share/factory/etc' \
    'AssertPathExists=/sysroot' \
    'ExecStartPre=/usr/bin/mkdir -p /sysroot/etc' \
    'ExecStartPre=/usr/bin/mount --no-canonicalize -t tmpfs -o mode=0755,size=16M,nosuid,nodev,noexec tmpfs /sysroot/etc' \
    'ExecStartPre=/usr/bin/mountpoint /sysroot/etc' \
    'ExecStartPre=/usr/bin/mkdir -p /sysroot/var/lib' \
    'ExecStartPre=/usr/bin/touch /sysroot/var/lib/machine-id' \
    'ExecStartPre=/usr/bin/ln -sfn /var/lib/machine-id /sysroot/etc/machine-id'; do
    grep -qxF "$line" "$TMPFS_DROPIN" ||
        die "$TMPFS_DROPIN is missing '$line' -- see the comment above the drop-in for what each line is load-bearing against"
done
# ...and the negative direction, which is the one that actually protects the
# property. A read-only bind of the empty unit-search-path over
# /etc/systemd/system used to sit here as well; it is gone because a tmpfs
# already gives an empty, non-persistent /etc/systemd/system, and keeping it
# would mean two mechanisms for one property and a detector that has to reason
# about both. Assert it has NOT come back, because its absence is the design:
#   /sysroot/usr/lib/vngrd  -- a directory that exists only to be bind-mounted
#   /etc/systemd/system     -- must be a plain empty tmpfs directory
grep -q 'unit-search-path' "$TMPFS_DROPIN" &&
    die "$TMPFS_DROPIN still contains the unit-search-path bind; the tmpfs replaces it and both together is two mechanisms for one property"
[ -e "$DST/usr/lib/vngrd/unit-search-path" ] &&
    die "usr/lib/vngrd/unit-search-path still exists; it existed only as the bind source and is now dead weight in the verified /usr"
# It must be a drop-in DIRECTORY and a drop-in, never a same-named replacement:
# a file at /etc/systemd/system/initrd-switch-root.service replaces the vendor unit
# and loses ExecStart=systemctl --no-block switch-root, OnFailure=emergency.target
# and DefaultDependencies=no, so the drop-in's ExecStartPre= lines would run against
# a unit that never pivots. That is a machine that stops booting, not one that is
# quietly unprotected, but it is still a break.
[ ! -e "$DST/etc/systemd/system/initrd-switch-root.service" ] ||
    die "/etc/systemd/system/initrd-switch-root.service replaces the vendor unit rather than merging with it; the mount belongs in $TMPFS_DROPIN"
[ -e "$DST/usr/lib/systemd/system/initrd-switch-root.service" ] ||
    die "the vendor initrd-switch-root.service must stay in the initrd; layer a drop-in on it instead of replacing it"

# A tree seed is copied verbatim, which brings along symlinks that point outside
# the initrd. Right now that is exactly one: usr/lib/systemd/ukify ->
# ../../bin/ukify, a build-time tool with no business in an initrd, and copying
# it would mean shipping a Python program and its pefile dependency for nothing.
# Pruned by the rule rather than by a deny-list, which rots silently when a name
# disappears or moves: a symlink inside a seeded tree whose target is not present
# in the initrd is not wanted here. That cannot leave a dangling link behind. The
# count is reported so a surprise is visible rather than quietly absorbed.
pruned=0
for l in $(find "$DST" -xtype l 2>/dev/null); do
    rm -f "$l"
    pruned=$((pruned + 1))
    note "pruned symlink with no target in the initrd: ${l#"$DST/"}"
done

# mkosi also creates these (configure_initrd). Creating them here too is harmless
# -- they are identical -- and means the tree is a complete, inspectable initrd
# on its own.
mkdir -p "$DST/etc"
ln -sfn /usr/lib/systemd/systemd "$DST/init"
ln -sfn /etc/os-release "$DST/etc/initrd-release"
ln -sfn ../usr/lib/os-release "$DST/etc/os-release"
printf 'LANG=C.UTF-8\n' > "$DST/etc/locale.conf"
cat > "$DST/etc/nsswitch.conf" <<'EOF'
passwd: files
group:  files
shadow: files
EOF
# nsswitch is files only: the initrd resolves nothing, so libnss_dns and
# libnss_myhostname would be dead weight. libnss_files is seeded above.
# /etc/machine-id ships empty rather than as the literal "uninitialized" the
# normal initramfs carries (PID 1 randomises it): the tree stays byte-comparable
# and nothing reads a machine-id that is not there.
: > "$DST/etc/machine-id"
# /etc/passwd and /etc/group: sulogin says "cannot open password database"
# without them. Failed-boot path only, but the emergency shell is the one thing
# between a bad boot and an operator staring at a dead machine.
printf 'root:x:0:0:root:/root:/sbin/nologin\n' > "$DST/etc/passwd"
printf 'root:x:0:\n' > "$DST/etc/group"
# No /etc/shadow, deliberately. sulogin will ask for a password nobody has and
# the emergency shell will not open -- which is the intended posture. Giving the
# initrd a root password, even an empty one, would put a root shell in the initrd
# namespace on any failed boot, and that namespace holds systemd, cryptsetup and
# mount(8).

# These are the things a future rootfs change could silently reintroduce, and
# every one of them is a size or security regression rather than a build error.

for p in usr/lib/repart.d usr/lib/pcrlock.d usr/lib/tmpfiles.d \
         usr/lib/sysusers.d usr/lib/udev/hwdb.bin usr/lib/udev/hwdb.d \
         usr/lib/locale usr/lib/pam.d usr/lib/modules usr/share usr/include; do
    [ -e "$DST/$p" ] || continue
    die "$p must not be in the initrd (see the comment at the top)"
done

# No .ko anywhere: the kernel is CONFIG_MODULES=n, so a module in the initrd
# would be inert weight at best.
if find "$DST" -name '*.ko' -print -quit | grep -q .; then
    die "a loadable module leaked into the initrd"
fi

# The override for systemd's built-in module-loader template. Asserted by name
# because its absence is not a build error: the initrd still assembles, still
# passes every other check, and fails at boot with five "Unable to locate
# executable" lines that t0 is the only thing reading.
[ -f "$DST/etc/systemd/system/modprobe@.service" ] ||
    die "missing the modprobe@ override (systemd's built-in template cannot exec, and t0 asserts on that)"

# vngrd-etc-confine.service is GONE, and this asserts that it stays gone rather
# than that it is merely unreferenced. It reported on the read-only bind of the
# empty unit-search-path over /etc/systemd/system, and the tmpfs replaces that
# mechanism: /etc is a fresh tmpfs at every boot, so /etc/systemd/system is an
# empty tmpfs directory and there is nothing to confine. A detector that still
# ran would be worse than no detector: it tests that /etc is on the writable
# LUKS2 root and that /etc/systemd/system is not a writable plain directory, and
# under this design the first of those is false on every healthy machine. It would
# print FAILED forever and be the one failure nobody believes.
[ ! -e "$DST/usr/lib/systemd/system/vngrd-etc-confine.service" ] ||
    die "vngrd-etc-confine.service is back: it reports on a bind mount that no longer exists and would read FAIL on every healthy machine"
[ ! -e "$DST/usr/lib/systemd/system/sysinit.target.wants/vngrd-etc-confine.service" ] ||
    die "vngrd-etc-confine.service is enabled: the unit is gone and this enablement is dangling"

# ...and asserted on its *ordering*, which is load-bearing and has no other check.
# A .service without DefaultDependencies=no is given After=sysinit.target and
# After=basic.target (src/core/service.c:748), and every unit that pulls this
# template in does Before=sysinit.target, so dropping either of the two lines
# below puts an ordering cycle in the initrd transaction. PID 1 then deletes a
# job to break it (src/core/transaction.c:406) and the initrd still assembles,
# still passes everything above, and still boots -- just not every time. Asserted
# by grep because the symptom is a boot that fails one time in five and an error
# message in a log nobody reads.
override="$DST/etc/systemd/system/modprobe@.service"
for line in 'DefaultDependencies=no' 'Before=sysinit.target'; do
    grep -qxF "$line" "$override" ||
        die "$override is missing '$line': without it systemd's service defaults order every modprobe@X after basic.target, which cycles against sys-kernel-config.mount, sys-fs-fuse-connections.mount and systemd-pstore.service (see the comment above)"
done

# A tmpfiles-setup or sysusers unit that is *absent* from the initrd is a
# regression: systemd-tmpfiles-setup.service carries `Before=sysinit.target' and
# many sysinit units carry a matching `After=', so deleting it drops an ordering
# edge and provokes the cryptsetup/basic.target cycle described above. What must
# be here is the condition drop-in that keeps the unit from running in the initrd.
# Asserted by name because nothing else in this script notices -- the initrd still
# assembles, and it still boots often enough to hide the rest of the time.
for u in systemd-tmpfiles-setup systemd-sysusers; do
    dropin="$DST/etc/systemd/system/$u.service.d/10-initrd.conf"
    [ -f "$dropin" ] ||
        die "missing $dropin: without it $u.service runs in the initrd, is left active (exited) by RemainAfterExit=yes, and the host's /etc is never created"
    grep -q 'ConditionPathExists=!/etc/initrd-release' "$dropin" ||
        die "$dropin does not gate $u.service to the host"
    # The gate must be a drop-in DIRECTORY. A same-named file in
    # /etc/systemd/system replaces the vendor unit instead of layering on it, and
    # the result does not load at all -- which loses the ordering edges this whole
    # block is trying to protect. Asserted because nothing else would notice.
    [ ! -e "$DST/etc/systemd/system/$u.service" ] ||
        die "/etc/systemd/system/$u.service replaces the vendor unit rather than merging with it; the gate belongs in $u.service.d/10-initrd.conf"
    [ -e "$DST/usr/lib/systemd/system/$u.service" ] ||
        die "the vendor $u.service must stay in the initrd for its ordering edges; gate it with a drop-in instead of deleting it"
done

# And the socket gate, for the same class of reason: without it the initrd logs
# `[FAILED] Failed to listen on Journal Log Access Socket.` on every boot, which
# is exactly the noise that makes a real failure easy to miss.
sd="systemd-journalctl.socket"
[ -f "$DST/etc/systemd/system/$sd.d/10-initrd.conf" ] ||
    die "missing $DST/etc/systemd/system/$sd.d/10-initrd.conf: $sd fails in the initrd with 'Unknown group systemd-journal'"
grep -q 'ConditionPathExists=!/etc/initrd-release' "$DST/etc/systemd/system/$sd.d/10-initrd.conf" ||
    die "$sd is not gated to the host"
[ ! -e "$DST/etc/systemd/system/$sd" ] ||
    die "$sd must be gated with a drop-in directory, not replaced with a same-named file"
[ -e "$DST/usr/lib/systemd/system/$sd" ] ||
    die "the vendor $sd must stay in the initrd"

# The fixate generator has to be in the initrd, with the cryptsetup binary it
# re-invokes. Both are silent failures without this.
# The generator is under usr/lib/systemd/, so seed_tree carries it automatically.
# That is exactly why it needs saying: a binary that arrives as a side effect of
# seeding a whole directory, for a purpose nothing else in that directory serves,
# is the kind of thing that stops being there when the seed list is reorganised --
# and it stops the fixate check rather than breaking anything visible. The root
# would open, every test that asks "does it unseal?" would pass, and the volume
# substitution defence would simply not be running.
# vngrd-cmdline-guard, and the .extra/signed-cmdline the patched stub writes into
# the initrd for it to compare against. The stub half of this is packages/systemd/
# build; the binary half arrives from ../vngrd-fixate-generator via the fixate
# install list in build.sh, so a seeding miss here is silent in the worst way: the
# unit then fails to exec on a missing binary on every boot. Assert both halves,
# and the enablement symlink that actually starts it -- Before= orders a unit, it
# does not start one. The guard is fail-closed: absence of the signed file is an
# error, not a skip, and it is ordered before the verity setup.
guard="usr/lib/vngrd/vngrd-cmdline-guard"
[ -x "$DST/$guard" ] ||
    die "missing $guard: nothing would compare the kernel command line against the signed one, so an SMBIOS Type 11 cmdline-extra appended to a signed command line would stand. Build it with ./build.sh (the fixate step)."
[ -f "$DST/usr/lib/systemd/system/vngrd-cmdline-guard.service" ] ||
    die "missing usr/lib/systemd/system/vngrd-cmdline-guard.service: the guard binary would ship with nothing running it"
[ -e "$DST/usr/lib/systemd/system/initrd-root-device.target.wants/vngrd-cmdline-guard.service" ] ||
    die "vngrd-cmdline-guard.service is not enabled: it exists but nothing starts it, which is the failure mode that leaves a boot trusting a command line it should not"
grep -q '^ExecStart=/usr/lib/vngrd/vngrd-cmdline-guard ' \
    "$DST/usr/lib/systemd/system/vngrd-cmdline-guard.service" ||
    die "vngrd-cmdline-guard.service does not exec $guard: the control is the program, not the unit"
grep -q '^Before=sysroot.mount sysusr-usr.mount systemd-veritysetup@usr.service$' \
    "$DST/usr/lib/systemd/system/vngrd-cmdline-guard.service" ||
    die "vngrd-cmdline-guard.service is not ordered before systemd-veritysetup@usr.service: the verity mount could act on an attacker-selected usrhash= before the command line is checked"
if grep -qx 'ConditionPathExists=/.extra/signed-cmdline' \
    "$DST/usr/lib/systemd/system/vngrd-cmdline-guard.service"; then
    die "vngrd-cmdline-guard.service still skips when .extra/signed-cmdline is absent: a UKI without .cmdline must fail the boot, not bypass the check"
fi
gen="usr/lib/systemd/system-generators/vngrd-fixate-generator"
[ -x "$DST/$gen" ] ||
    die "missing $gen: the root volume key would not be checked against the fixate digest frozen in NV, so a substituted volume would open. Build it with ./build.sh (the fixate step)."
nvw="usr/lib/vngrd/vngrd-fixate-nvwrite"
[ -x "$DST/$nvw" ] ||
    die "missing $nvw: nothing would ever freeze the digest, so the generator would find no NV index and the fixate check would never run. This is the same silent outcome as a missing generator."
unit="usr/lib/systemd/system/vngrd-fixate.service"
[ -f "$DST/$unit" ] ||
    die "missing $unit: the digest is computed by repart on the boot that creates the volume and exists nowhere else, so without this unit the register is never written"
[ -e "$DST/usr/lib/systemd/system/initrd-root-fs.target.wants/vngrd-fixate.service" ] ||
    die "vngrd-fixate.service is not enabled: it exists but nothing starts it, and because the digest only exists on the boot that creates the volume, an unrun unit is indistinguishable from a machine that was never provisioned"
# The freeze has to land inside the PCR 11 window. If leave-initrd ever ran first
# the write would still succeed -- it needs no key -- but it would be storing a
# digest taken from a value nobody can recompute, and nothing would ever notice.
grep -q '^Before=vngrd-leave-initrd.service' "$DST/$unit" ||
    die "$unit is not Before=vngrd-leave-initrd.service: the NV write must complete before the PCR 11 key-availability window closes"
# The path is hardcoded in src/fixate.c (SYSTEMD_CRYPTSETUP_PATH) because the
# alternative is reading the ExecStart that systemd-cryptsetup-generator wrote,
# which would make the generator depend on the order the two run in. Asserted here
# so a bindir change is a build failure rather than an ExecStart that re-invokes a
# path that does not exist -- which would fail the unlock with the console saying
# nothing about a missing binary.
[ -x "$DST/usr/bin/systemd-cryptsetup" ] ||
    die "missing usr/bin/systemd-cryptsetup: $gen hardcodes that path (SYSTEMD_CRYPTSETUP_PATH, matching systemd's meson.build:287) and would produce an ExecStart that cannot run"

# The GPT freeze rides on that same unit. It is asserted here rather than in a seed
# list because it has no seed-bin entry of its own: it arrives with usr/lib/vngrd,
# which seed_tree copies whole. That is exactly the side-effect arrival the note
# above the generator warns about, so it is named.
grep -q '^ExecStart=/usr/lib/vngrd/vngrd-gpt-freeze' "$DST/$unit" ||
    die "$unit does not run vngrd-gpt-freeze: nothing would ever write VNGRD_NV_GPT_INDEX, and a provisioned machine would have no GPT identity to check"
# The ESP freeze is the third ExecStart of that unit, and it gets its own line for
# the same reason with a detail that is its own: esp.c's digest is of the ESP as it
# is on the boot that freezes it, and every later boot rewrites files the digest
# deliberately excludes (esp.h). If that exclusion list and this ExecStart ever
# drift apart the failure is a reboot loop on the SECOND boot of a machine that
# provisions fine -- so the assertion that the freeze runs at all is the cheap half
# of keeping them honest.
grep -q '^ExecStart=/usr/lib/vngrd/vngrd-esp-freeze' "$DST/$unit" ||
    die "$unit does not run vngrd-esp-freeze: nothing would ever write VNGRD_NV_ESP_INDEX, and a provisioned machine would have no ESP identity to check"

# The rollback floor, the GPT identity, the ESP contents and the fixate digest:
# four initrd guards, the units that run them, the enablement that actually starts
# them, and the executables themselves. Every one of these is silent on its own:
#   - no enablement symlink -> the guard is never in the transaction (Before= orders
#     a unit, it does not start one), and a machine with no downgrade check is
#     indistinguishable from one that has nothing to check;
#   - no executable -> the unit fails at exec, and with FailureAction=reboot-force
#     that is a machine that never finishes booting -- on the boot the guard was
#     supposed to let through;
#   - the executable arrives through the usr/lib/vngrd tree seed rather than a
#     seed_bin entry, so a seed-tree reorganisation would drop it with no build
#     error at all.
# The counter-creation half of the same window. vngrd-fixate.service runs
# vngrd-rollback-commit --create on the provisioning boot; the binary arrives via
# the usr/lib/vngrd tree seed, so a seed reorganisation would drop it silently and
# the first boot would leave the guard with no floor to read.
commit="usr/lib/vngrd/vngrd-rollback-commit"
[ -x "$DST/$commit" ] ||
    die "missing $commit: nothing would define VNGRD_NV_ROLLBACK_INDEX on the provisioning boot, so vngrd-rollback-guard would fail closed on the next boot of a machine that was provisioned correctly. Build it with ./build.sh (the fixate step)."
grep -qx 'ExecStart=/usr/lib/vngrd/vngrd-rollback-commit --create /sysusr/usr/lib/os-release' "$DST/$unit" ||
    die "$unit does not create the rollback counter from the verified /usr: the floor must be defined once, on the boot that created the root, and from the version the kernel will run"

for u in vngrd-rollback-guard vngrd-gpt-guard vngrd-esp-guard vngrd-fixate-guard; do
    [ -x "$DST/usr/lib/vngrd/$u" ] ||
        die "missing usr/lib/vngrd/$u: the control is the program, and without it the boot is unchecked. Build it with ./build.sh (the fixate step)."
    [ -f "$DST/usr/lib/systemd/system/$u.service" ] ||
        die "missing usr/lib/systemd/system/$u.service: /usr/lib/vngrd/$u would ship with nothing running it"
    [ -e "$DST/usr/lib/systemd/system/initrd-root-fs.target.wants/$u.service" ] ||
        die "$u.service is not enabled from initrd-root-fs.target: it exists but nothing starts it"
    grep -q "^ExecStart=/usr/lib/vngrd/$u\( \|$\)" "$DST/usr/lib/systemd/system/$u.service" ||
        die "$u.service does not exec /usr/lib/vngrd/$u"
    # Ordering and failure action, on the unit. A guard moved to After=sysroot.mount
    # would run after the root it gates; one without FailureAction= would fail and
    # let the boot continue past the check.
    grep -qx 'Before=sysroot.mount' "$DST/usr/lib/systemd/system/$u.service" ||
        die "$u.service is not Before=sysroot.mount: it would run after the root was mounted"
    grep -Fqx 'Before=systemd-cryptsetup@vngrd\x2droot.service' "$DST/usr/lib/systemd/system/$u.service" ||
        die "$u.service is not before systemd-cryptsetup@vngrd\x2droot.service: Before=sysroot.mount alone leaves it able to race the unseal, so the volume key could be released before the check has run"
    grep -qx 'After=sysusr-usr.mount systemd-repart.service' "$DST/usr/lib/systemd/system/$u.service" ||
        die "$u.service is not After=sysusr-usr.mount systemd-repart.service: it reads the verified /usr and must not run before it exists, and it must not observe repart's intermediate state where the root partition exists but the fixate option does not"
    grep -qx 'FailureAction=reboot-force' "$DST/usr/lib/systemd/system/$u.service" ||
        die "$u.service has no FailureAction=reboot-force: a refusal would be a failed unit the boot continues past"
done
# The rollback guard reads the version from the VERIFIED /usr. In the initrd that is
# /sysusr/usr/lib/os-release; /usr/lib/os-release is the initramfs's own copy, which
# is a different tree.
# The recovery-passphrase wrapper is a local program, not a seed-bin entry: it
# arrives through the usr/lib/vngrd tree seed, which is exactly the kind of
# side-effect arrival that stops silently. Both the provisioning unit and the
# reseal unit exec it; a missing wrapper would fail provisioning before the
# passphrase keyslot exists, and fail reseal at the moment the machine is already
# relying on that keyslot.
pass="usr/lib/vngrd/vngrd-passphrase"
[ -x "$DST/$pass" ] ||
    die "missing $pass: both vngrd-provision.service and vngrd-reseal.service exec it, and a missing wrapper is a missing recovery keyslot. Build it with ./build.sh (the fixate step)."
grep -q '^ExecStart=/usr/lib/vngrd/vngrd-passphrase --new -- /usr/bin/systemd-cryptenroll ' \
    "$DST/usr/lib/systemd/system/vngrd-provision.service" ||
    die "vngrd-provision.service does not enroll through $pass: the quality floor and the two-entry check would not run"
reseal="usr/lib/systemd/system/vngrd-reseal.service"
[ -f "$DST/$reseal" ] ||
    die "missing $reseal: a dbx or firmware update that moves PCR 7 would leave the recovery passphrase as the only way in on every boot"
[ -e "$DST/usr/lib/systemd/system/initrd-root-fs.target.wants/vngrd-reseal.service" ] ||
    die "vngrd-reseal.service is not enabled from initrd-root-fs.target: it exists but nothing starts it"
grep -q '^ExecStart=/usr/lib/vngrd/vngrd-passphrase --current -- /usr/bin/systemd-cryptenroll ' \
    "$DST/$reseal" ||
    die "vngrd-reseal.service does not unlock through $pass: the old token is the one that just failed"
grep -q '^Before=vngrd-leave-initrd.service initrd-switch-root.service initrd-switch-root.target$' \
    "$DST/$reseal" ||
    die "vngrd-reseal.service is not before the leave-initrd measurement: the new token could never be satisfied"

grep -q '^ExecStart=/usr/lib/vngrd/vngrd-rollback-guard /sysusr/usr/lib/os-release' \
    "$DST/usr/lib/systemd/system/vngrd-rollback-guard.service" ||
    die "vngrd-rollback-guard.service does not read /sysusr/usr/lib/os-release: the version it decides on has to be the verified tree's"
grep -Fqx 'Before=systemd-cryptsetup@vngrd\x2droot.service' \
    "$DST/usr/lib/systemd/system/vngrd-rollback-guard.service" ||
    die "vngrd-rollback-guard.service is not before systemd-cryptsetup@vngrd\x2droot.service: it would decide after the TPM released the root key to the old image"

# The generator links libtss2, and reading an NV index needs /dev/tpmrm0 to exist
# at GENERATOR time -- before udev, before any unit. That is why CONFIG_TCG_TPM,
# CONFIG_TCG_TIS, CONFIG_TCG_CRB and CONFIG_DEVTMPFS are all =y in the kernel
# config, and it is a silent failure otherwise: no node, no TCTI, no check.
for so in libtss2-esys.so.0 libtss2-tctildr.so.0 libtss2-rc.so.0; do
    [ -e "$DST/usr/lib/$so" ] ||
        die "missing usr/lib/$so: $gen links it and the closure walk did not pull it in, so it would fail to load before doing anything"
done

# The two files that vngrd-rootfs/scripts/verify.sh allows as inert violations
# must not be here. verify.sh lets them through with a comment claiming they are
# unreachable; that claim is only worth anything if the initrd is checked for it,
# because seed_tree copies usr/lib trees wholesale and could easily start carrying
# one. Both are systemd-shipped and both would be a real finding if they arrived.
for p in usr/lib/environment.d/99-environment.conf \
         usr/lib/kernel/install.d/90-loaderentry.install; do
    [ ! -e "$DST/$p" ] ||
        die "$p is in the initrd: verify.sh allows it in the rootfs on the grounds that nothing reaches it, and that is no longer true"
done

# No dangling symlink anywhere. Every one of these is a failure the initrd cannot
# report usefully: the loader prints one line and moves on, and because
# systemd-tpm2-setup-early runs with --graceful the visible symptom is a
# cryptsetup unit failing much later with no obvious cause.
dangling=$(find "$DST" -xtype l 2>/dev/null || true)
if [ -n "$dangling" ]; then
    echo "$0: dangling symlinks in the initrd root:" >&2
    echo "$dangling" | sed "s|^$DST/|  |" >&2
    exit 1
fi

# Three things have to arrive together or the seal is unsatisfiable: the unit,
# the binary it execs, and the enablement. Any one of them missing means
# enter-initrd is never measured, PCR 11 stays at the stub-only value, and since
# the UKI's .pcrsig signs the *post*-enter-initrd value (scripts/ukify in
# vngrd-image), the TPM's PolicyAuthorize matches nothing and the root never
# opens. The failure surfaces as a cryptsetup failure with no TPM message,
# because the absent thing is not obviously related to unsealing -- so it is
# checked here rather than discovered on a booted machine.
for p in usr/lib/systemd/system/systemd-pcrphase-initrd.service \
         usr/lib/systemd/system/initrd.target.wants/systemd-pcrphase-initrd.service \
         usr/lib/systemd/systemd-pcrextend; do
    [ -e "$DST/$p" ] ||
        die "missing $p: the initrd cannot extend the enter-initrd PCR 11 phase, and the signed .pcrsig covers only that value"
done
# The host-side phases must not be *enabled* in the initrd. The unit files
# themselves stay -- they are part of usr/lib/systemd, which seed_tree copies
# wholesale, and deleting them would be a different change with a different
# risk -- so this checks the .wants symlinks, which is what decides whether they
# run. packages/base-files/build removes those symlinks from the rootfs, and
# this is the check that it did. The window ends at leave-initrd; a host phase
# measured here would extend PCR 11 past it.
for p in sysinit.target.wants/systemd-pcrphase-sysinit.service \
         sysinit.target.wants/systemd-pcrphase.service; do
    [ ! -e "$DST/usr/lib/systemd/system/$p" ] ||
        die "$p is enabled in the initrd: the root volume key's window is stages 4-6, not the whole boot"
done
# The two halves of the window, in the units that actually measure them. They are
# two units and not one because systemd's ExecStop is not orderable against the
# enrolment: Conflicts=initrd-switch-root.target makes the stop run as soon as
# switch-root is queued, and systemd orders a shutdown before a concurrent
# start-up whenever the two units have any ordering dependency, so leave-initrd
# used to be extended while systemd-cryptenroll held a TPM session open over
# PCR 11. The TPM answered TPM2_RC_PCR_CHANGED (0x128) and the passphrase keyslot
# was never enrolled. See
# usr/lib/systemd/system/systemd-pcrphase-initrd.service.d/10-vngrd.conf.
pp_u="$DST/usr/lib/systemd/system/systemd-pcrphase-initrd.service"
pp_d="$DST/usr/lib/systemd/system/systemd-pcrphase-initrd.service.d/10-vngrd.conf"
lv_u="$DST/usr/lib/systemd/system/vngrd-leave-initrd.service"
lv_w="$DST/usr/lib/systemd/system/initrd-switch-root.target.wants/vngrd-leave-initrd.service"
for p in "$pp_u" "$pp_d" "$lv_u"; do
    [ -e "$p" ] ||
        die "missing ${p#"$DST"/}: the initrd cannot measure both ends of the PCR 11 window, so the signed .pcrsig either matches nothing or the key stays releasable after switch-root"
done
[ -e "$lv_w" ] ||
    die "missing ${lv_w#"$DST"/}: vngrd-leave-initrd.service exists but nothing starts it, so leave-initrd is never measured"
# The drop-in must be in the initrd, not just the host: repart and the phase units
# are seeded from the host tree, and a drop-in that only existed host-side would
# leave the vendor ExecStop in force in the initrd, which is where the race was.
grep -q '^\[Service\]' "$pp_d" ||
    die "10-vngrd.conf has no [Service] section: ExecStop= in [Unit] is silently ignored, so the vendor ExecStop stays in force and the enrolment loses the race again"
sed -n '/^\[Service\]/,$p' "$pp_d" | sed 's/^[[:space:]]*#.*//' | grep -q '^ExecStop=$' ||
    die "10-vngrd.conf does not reset ExecStop= inside [Service]; the vendor ExecStop will still extend leave-initrd at the first opportunity"
# enter-initrd, and the phase string the .pcrsig is signed over.
grep -q 'systemd-pcrextend --graceful enter-initrd' "$pp_u" ||
    die "systemd-pcrphase-initrd.service does not extend enter-initrd; the signed phase and the measured phase must be the same string"
# leave-initrd, now in its own unit and ordered after the enrolment.
grep -q 'systemd-pcrextend --graceful leave-initrd' "$lv_u" ||
    die "vngrd-leave-initrd.service does not extend leave-initrd, so the TPM keeps releasing the volume key for the rest of the boot"
grep -q '^After=vngrd-provision.service' "$lv_u" ||
    die "vngrd-leave-initrd.service is not After=vngrd-provision.service; the window would close while systemd-cryptenroll still held a session open over PCR 11 (TPM2_RC_PCR_CHANGED, 0x128), and the passphrase would never be enrolled"

# systemd-analyze verify is not run here, but the drop-ins are the files whose
# absence is silent and fatal, so check the three that matter by name.
for d in usr/lib/systemd/system/systemd-repart.service.d/10-device.conf \
         usr/lib/systemd/system/sysroot.mount.d/10-repart.conf \
         usr/lib/systemd/system/systemd-cryptsetup@.service.d/10-repart.conf; do
    [ -f "$DST/$d" ] || die "missing $d (its absence fails the first boot silently)"
done
[ -f "$DST/usr/lib/udev/rules.d/10-dm.rules" ] ||
    die "missing 10-dm.rules (nothing else creates /dev/mapper/*)"
[ -e "$DST/usr/lib/udev/rules.d/60-persistent-storage.rules" ] ||
    die "missing 60-persistent-storage.rules (no by-partlabel/by-partuuid)"
# The initrd's own /etc/crypttab, copied in rather than seeded.
# Two constraints make seeding the wrong mechanism. usr/share is BANNED from the
# initrd (asserted below and at the top of this file) and it is where the file
# now lives, because /etc is a tmpfs and the image ships no /etc payload at all.
# And the path the initrd's generator reads is $DST/etc/crypttab -- the initrd's
# own /etc, which is the UKI's, which is signed. So the content comes from the
# verity'd factory tree and lands at the path the generator will read.
# This is the crypttab that gates the unlock, so it is the file the whole TPM
# design rests on. It is inside the signed UKI, which is the only reason that is
# worth anything; an ESP copy would be attacker-writable and is exactly the
# mistake the fixate value was designed to avoid.
[ -f "$SRC/usr/share/factory/etc/crypttab" ] ||
    die "missing usr/share/factory/etc/crypttab in the rootfs"
mkdir -p "$DST/etc"
install -m 0644 "$SRC/usr/share/factory/etc/crypttab" "$DST/etc/crypttab"
[ -f "$DST/etc/crypttab" ] || die "crypttab did not land at \$DST/etc/crypttab"
[ -e "$DST/usr/lib/os-release" ] || die "missing usr/lib/os-release (check_root_populated needs it)"

# The three generators the whole boot chain is made of, the executor, the
# cryptsetup token plugin, and systemd's built-in mount/umount defaults. All are
# reached by *path* or by dlopen, never by DT_NEEDED, so the closure walk cannot
# find them -- and every one of them shipped broken in an earlier version of this
# script, caught only by booting.
for f in usr/lib/systemd/systemd-executor \
         usr/lib/systemd/system-generators/systemd-cryptsetup-generator \
         usr/lib/systemd/system-generators/systemd-veritysetup-generator \
         usr/lib/systemd/system-generators/systemd-fstab-generator \
         usr/lib/cryptsetup/libcryptsetup-token-systemd-tpm2.so \
         usr/bin/mount usr/bin/umount; do
    [ -e "$DST/$f" ] && continue
    echo "$0: missing $f" >&2
    case "$f" in
        usr/bin/mount|usr/bin/umount)
            echo "     systemd substitutes these for .mount units, which have no" >&2
            echo "     ExecStart= of their own. Nothing scanning the unit files finds" >&2
            echo "     them, and without mount every API VFS mount and the verity /usr" >&2
            echo "     mount fail while the boot still looks like it is working." >&2
            ;;
        *libcryptsetup-token*)
            echo "     dlopened by libcryptsetup by name. Nothing links it and" >&2
            echo "     systemd-cryptsetup never forks, so the closure walk and any" >&2
            echo "     scan of the unit files both miss it. The root then does not" >&2
            echo "     unseal and repart succeeding does not make it better." >&2
            ;;
        *)
            echo "     Reached by path, not by DT_NEEDED, so the closure walk cannot" >&2
            echo "     find it: no generator runs, or PID 1 dies before mounting" >&2
            echo "     anything." >&2
            ;;
    esac
    exit 1
done

# The dlopen'd TSS2 set, asserted by name: a missing one is not a missing-exec
# error, because systemd-tpm2-setup-early runs with --graceful and reports
# success, and the only visible failure is the root refusing to unseal later.
# libtss2-tcti-device specifically, since tpm2-device=auto resolves to the
# compiled-in "device:/dev/tpmrm0" and no other TCTI is ever loaded.
for l in libtss2-esys.so.0 libtss2-mu.so.0 libtss2-rc.so.0 libtss2-tcti-device.so.0; do
    [ -f "$DST/usr/lib/$l" ] || die "missing usr/lib/$l (root cannot unseal)"
done
[ -f "$DST/usr/lib/libnss_files.so.2" ] ||
    die "missing libnss_files.so.2 (glibc dlopens NSS modules; getpwnam fails without it)"

# Every DT_NEEDED of every ELF in the tree must resolve to a file in the tree.
# The walk above cannot find a missing sibling directory or a missing sibling
# binary, so this walks the finished tree in both directions and demands that it
# be self-contained.
bad=0
for f in $(find "$DST" -type f 2>/dev/null); do
    "$READELF" -d "$f" 2>/dev/null | grep -q '(NEEDED)' || continue
    for n in $("$READELF" -d "$f" 2>/dev/null |
               sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p'); do
        found=0
        for d in usr/lib usr/lib/systemd usr/lib64 lib; do
            if [ -e "$DST/$d/$n" ]; then
                found=1
                break
            fi
        done
        [ "$found" = 1 ] && continue
        echo "$0: $f needs $n, which is not in the initrd" >&2
        bad=1
    done
done
[ "$bad" -eq 0 ] || exit 1

# Three passes, because the three ways a unit can name a program are each
# invisible to the other two: absolute ExecStart= paths; *bare* names, which
# systemd resolves through its own search path; and the built-in defaults
# systemd substitutes for unit types with no ExecStart= at all. Each of the first
# two shipped broken before this check existed.
# Not every referenced program belongs in an initrd, so the ones deliberately
# left out are named rather than silently tolerated: a systemd bump that starts
# referencing something new should fail here and force a decision.
unit_exec_words() {
    # Both trees, not just the vendor one. The initrd's /etc/systemd/system holds
    # three overrides of ours (modprobe@.service and two drop-in directories) and
    # they are the units the rest of the initrd transaction is most sensitive to --
    # a modprobe@.service that cannot exec is five "Unable to locate executable"
    # lines and a boot that hangs. Scanning only usr/lib/systemd/system cannot see
    # them, and a file in a higher-precedence directory *replaces* the vendor unit
    # of the same name rather than layering on it, so a broken one is not caught by
    # anything else either.
    grep -rhoE '^(ExecStart|ExecStartPre|ExecStartPost|ExecCondition)=[^ ]*' \
        "$DST/usr/lib/systemd/system" "$DST/etc/systemd/system" 2>/dev/null |
        sed -E 's/^[A-Za-z]+=//; s/^[+-]//' |
        awk '{print $1}'
}


resolve_bare() {
    for d in usr/bin usr/sbin usr/lib/systemd usr/lib; do
        [ -x "$DST/$d/$1" ] && return 0
    done
    return 1
}

for b in $(unit_exec_words | grep -v '^/' | grep -vE '^$|^\(' | sort -u); do
    resolve_bare "$b" && continue
    grep -qE "^$b([[:space:]]|$)" "$HERE/initrd/skip-bare.txt" && continue
    echo "$0: a unit execs '$b' by bare name and it is not in the initrd." >&2
    echo "     systemd resolves bare names through its own search path, so neither" >&2
    echo "     the DT_NEEDED closure nor a scan for absolute paths will find this." >&2
    echo "     Add it to seed_bin, or name it in skip_bare with a reason." >&2
    bad=1
done
[ "$bad" -eq 0 ] || exit 1


for b in $(unit_exec_words | grep '^/' | sort -u); do
    [ -e "$DST$b" ] && continue
    grep -qF -- "$b" "$HERE/initrd/host-only.txt" && continue
    echo "$0: a unit execs $b, which is not in the initrd" >&2
    bad=1
done
[ "$bad" -eq 0 ] || exit 1

# Pass 3: systemd's own built-in defaults, which appear in no unit file at all.
for f in usr/bin/mount usr/bin/umount; do
    [ -x "$DST/$f" ] || die "missing $f (systemd's built-in default for .mount units)"
done

n=$(find "$DST" -mindepth 1 | wc -l)
sz=$(du -sh "$DST" | cut -f1)
printf 'initrd root: %s entries, %s -> %s\n' "$n" "$sz" "${DST#"$ROOT/../"}"
}
