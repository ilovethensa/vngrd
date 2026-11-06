#!/usr/bin/fish
# The vngrd boot gate: checks that must hold before systemd-bless-boot strips the
# boot counter from the slot we booted.
#
# dm-verity has already verified every byte of /usr against the signed usrhash=,
# so re-reading files proves nothing. What it cannot check is the bookkeeping
# around /usr:
#   1. /usr is a mount, and it is the verity volume. Otherwise it is the copy
#      inside the initrd: bootable and entirely unverified.
#   2. The partitions named by usrhash= exist and their GPT labels agree with
#      IMAGE_VERSION=. The label is sysupdate's version store; if they disagree,
#      the next update treats the running slot as older and overwrites it.
#   3. /etc/os-release is the symlink into /usr, not a frozen copy.
#
# Cheap by construction: no network, sleeps, loops, or blocking device I/O.
#
# The .fish suffix matters: /usr/bin/sh is fish here, so #!/bin/sh would promise
# the wrong language. `version' is read-only in fish, hence imgver.


set -g nfail 0

function fail
    set -g nfail (math $nfail + 1)
    echo "vngrd-boot-gate: FAIL: $argv"
end

function ok
    echo "vngrd-boot-gate: ok:   $argv"
end

# Offsets are into the undashed string: 1/9/13/17/21, not dashed offsets.
function dashed-uuid --description 'reformat 32 hex chars as a dashed UUID'
    set -l h $argv[1]
    echo (string sub -l 8 -- $h)"-"(string sub -s 9 -l 4 -- $h)"-"(string sub -s 13 -l 4 -- $h)"-"(string sub -s 17 -l 4 -- $h)"-"(string sub -s 21 -- $h)
end

# lsblk --raw sometimes pads the last column, and a trailing blank line makes
# fish's `set x (...)' a two-element list whose interpolation rejoins with a
# space. Strip spaces and take the first element. GPT labels here never contain
# one, and sysupdate's MatchPattern assumes the same.
function part-label --description 'PARTLABEL of a block device, unpadded'
    set -l l (lsblk --raw --noheadings --output PARTLABEL $argv[1] | string replace --all ' ' '')
    echo $l[1]
end

# /dev/mapper/usr is the name veritysetup-generator gives the volume; the udev
# rule creates the symlink. Resolve both sides so /dev/dm-N and the mapper name
# compare as the same node.
set -l src (findmnt --mountpoint /usr --noheadings --output SOURCE)
set -l want_src (readlink -f /dev/mapper/usr)

if test -z "$want_src"
    fail "/dev/mapper/usr is gone: the verity volume this slot runs from does not exist"
else if test (count $src) -eq 0
    fail "/usr is not a mount point, so nothing put a verified filesystem there: /usr is whatever the initrd carried"
else if test (count $src) -ne 1
    fail "/usr has (count $src) mount points, expected one: $src"
else if test (readlink -f -- $src[1]) != $want_src
    fail "/usr is mounted from $src[1], expected the verity volume $want_src"
else
    ok "/usr is the verity volume ($src[1])"
end

# Read from /usr/lib/os-release, inside the verified tree; check 3 notices a stale
# /etc symlink.
set -l imgver (pcre2grep --only-matching=1 '^IMAGE_VERSION=([^[:space:]]+)' /usr/lib/os-release \
    | string replace --all '"' '' | string trim)

# usrhash= is the Merkle root: first 128 bits are the data partition's GPT UUID,
# last 128 the verity partition's. The rd. prefix is stripped because the
# generator strips it.
set -l usrhash (pcre2grep --only-matching=1 '(?:^|\s)(?:rd\.)?usrhash=([0-9a-fA-F]{32,})' /proc/cmdline \
    | string lower)

if test (count $imgver) -ne 1
    fail "/usr/lib/os-release has no IMAGE_VERSION: sysupdate's ProtectVersion=%A and MinVersion=%A would both expand to nothing and be dropped with a warning"
else if test (count $usrhash) -ne 1
    fail "/proc/cmdline has no usrhash=, so nothing authenticated /usr and no slot was selected"
else
    # udev's by-partuuid links use the canonical dashed form, so re-dash the
    # halves or every lookup names a node that does not exist.
    set -l h $usrhash[1]
    set -l data_node /dev/disk/by-partuuid/(dashed-uuid (string sub -l 32 -- $h))
    set -l verity_node /dev/disk/by-partuuid/(dashed-uuid (string sub -s 33 -- $h))

    if not test -e $data_node
        fail "$data_node, the data partition usrhash= names, does not exist"
    else if not test -e $verity_node
        fail "$verity_node, the verity partition usrhash= names, does not exist"
    else
        set -l want vngrd-usr_$imgver
        set -l got (part-label $data_node)
        if test "$got" = "$want"
            ok "data partition is labelled $want"
        else
            fail "data partition $data_node is labelled '$got', but IMAGE_VERSION=$imgver makes it '$want'"
        end

        set -l want_v vngrd-usr_{$imgver}_verity
        set -l got_v (part-label $verity_node)
        if test "$got_v" = "$want_v"
            ok "verity partition is labelled $want_v"
        else
            fail "verity partition $verity_node is labelled '$got_v', but IMAGE_VERSION=$imgver makes it '$want_v'"
        end
    end
end

# tmpfiles rules can be skipped, run late, or run against another root, and
# systemd's plain L= rule will not replace a regular file. This is the only
# detector for a replaced /etc/os-release; the version check reads from verified
# /usr so it cannot be made to lie.
if not test -e /etc/os-release
    fail "/etc/os-release does not exist: the symlink into /usr is gone, and IMAGE_VERSION= has no source for sysupdate to read"
else if not test /etc/os-release -ef /usr/lib/os-release
    fail "/etc/os-release is a copy, frozen at whatever version was installed: it has to be the symlink into /usr, or sysupdate protects the wrong slot"
else
    ok "/etc/os-release is /usr/lib/os-release"
end

# Non-zero fails vngrd-boot-gate.service, which boot-complete.target Requires=,
# which systemd-bless-boot Requires=. Deliberately no remediation: `bad' is
# irreversible, and a gate that can be wrong must not spend attempts automatically.
# An inconsistent slot costs at most three inspectable boots.
if test $nfail -gt 0
    echo "vngrd-boot-gate: $nfail check(s) failed. Leaving the boot counter alone: sd-boot will fall back to the other slot once this one's attempts run out, and 'systemd-bless-boot bad' skips straight there."
    exit 1
end

echo "vngrd-boot-gate: all checks passed: systemd-bless-boot will strip the boot counter."
exit 0
