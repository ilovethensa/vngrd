#!/bin/sh -e
# Runs inside the builder container.

FRAGMENT=/config/configs/vngrd.config
KCONFIG_LOG=/tmp/kconfig.log

if [ ! -r "$FRAGMENT" ]; then
    echo "ERROR: $FRAGMENT is not readable." >&2
    echo "       scripts/build.sh has to mount vngrd-kernel/configs/ into the" >&2
    echo "       container; that file is where every security decision now lives," >&2
    echo "       so there is nothing to fall back to." >&2
    exit 1
fi

if [ -s /config/kernel.config ]; then
    echo "Using stored config /config/kernel.config"
    # Only copy if different to keep .o cache valid for incremental builds
    if ! cmp -s /config/kernel.config .config 2>/dev/null; then
        cp /config/kernel.config .config
    else
        echo "Config unchanged, keeping existing .config for incremental build"
    fi
else
    echo "No stored config, generating defconfig"
    make ARCH=x86_64 LLVM=1 defconfig
fi

# Merge fragment onto base (kernel %.config target sequence), -m = merge only.
# -m keeps make invocation ours (arch/toolchain); -s (strict) unused since redefining base is intended.
echo "Merging $FRAGMENT onto .config"
sh scripts/kconfig/merge_config.sh -m .config "$FRAGMENT"

# Kconfig diagnostics escalated: unknown symbols fail; changed input scraped below.
if ! KCONFIG_WARN_UNKNOWN_SYMBOLS=1 KCONFIG_WERROR=1 KCONFIG_WARN_CHANGED_INPUT=1 \
     make ARCH=x86_64 LLVM=1 olddefconfig 2>"$KCONFIG_LOG"; then
    cat "$KCONFIG_LOG" >&2
    echo >&2
    echo "ERROR: olddefconfig failed. With KCONFIG_WERROR=1 that is almost always an" >&2
    echo "       unknown symbol: a config key that no Kconfig file in $(pwd) declares," >&2
    echo "       so either kernel.config or $FRAGMENT names something this" >&2
    echo "       kernel release does not have. The offending line is above." >&2
    exit 1
fi
if grep -q 'unknown symbol' "$KCONFIG_LOG"; then
    grep 'unknown symbol' "$KCONFIG_LOG" >&2
    echo "ERROR: unknown symbol in the config input (see above)" >&2
    exit 1
fi

# Print values Kconfig changed while resolving (dependency graph), not oversights.
echo "--- values Kconfig changed while resolving the fragment ---"
sed -n '/^warning: user-provided values changed by Kconfig:/,$p' "$KCONFIG_LOG" || true

# Fragment-requested symbol not honoured -> build failure.
sed -n 's/^  \(CONFIG_[A-Za-z0-9_]*\): .* -> .*$/\1/p' "$KCONFIG_LOG" | sort -u > /tmp/kconfig.changed
sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=.*/\1/p
        s/^# \(CONFIG_[A-Za-z0-9_]*\) is not set$/\1/p' "$FRAGMENT" | sort -u > /tmp/kconfig.claimed
overrides="$(comm -12 /tmp/kconfig.changed /tmp/kconfig.claimed || true)"
if [ -n "$overrides" ]; then
    echo >&2
    echo "ERROR: Kconfig did not honour these fragment values:" >&2
    echo "$overrides" | sed 's/^/       /' >&2
    echo "       The 'old -> new' lines above say what each one became. If the value" >&2
    echo "       is still the right one, the fragment is wrong about it; if it is not," >&2
    echo "       the decision it records no longer holds in this kernel release." >&2
    exit 1
fi

# Same check directly on files (covers values Kconfig log omits).
awk '
    function sym(line) {
        if (line ~ /^CONFIG_[A-Za-z0-9_]+=/) {
            i = index(line, "=")
            return substr(line, 1, i - 1)
        }
        if (line ~ /^# CONFIG_[A-Za-z0-9_]+ is not set$/) {
            s = line
            sub(/^# /, "", s)
            sub(/ is not set$/, "", s)
            return s
        }
        return ""
    }
    function val(line) {
        if (line ~ /^CONFIG_[A-Za-z0-9_]+=/) {
            i = index(line, "=")
            return substr(line, i + 1)
        }
        if (line ~ /^# CONFIG_[A-Za-z0-9_]+ is not set$/)
            return "n"
        return ""
    }
    FNR == NR { k = sym($0); if (k != "") req[k] = val($0); next }
    { k = sym($0); if (k != "") got[k] = val($0) }
    END {
        for (k in req) {
            g = (k in got) ? got[k] : "absent"
            if (g == "absent" && req[k] == "n")
                continue
            if (g != req[k])
                print k ": requested " req[k] ", final " g
        }
    }' "$FRAGMENT" .config > /tmp/kconfig.mismatch || {
        echo "ERROR: could not compare $FRAGMENT against .config" >&2
        exit 1
    }
if [ -s /tmp/kconfig.mismatch ]; then
    sort /tmp/kconfig.mismatch >&2
    echo "ERROR: the config that was built disagrees with the fragment (above)" >&2
    exit 1
fi
echo "fragment values honoured: $(wc -l < /tmp/kconfig.claimed) symbols requested, all as written"

# Assert integrity settings survive olddefconfig (negations not caught above).
# must_be_on: present (=y); must_be_off: absent (no =y/=m), incl. dropped symbols.
# Lockdown floor integrity; lockdown does not cover EFI writes or perf_event_open.
must_be_off="CONFIG_MODULES CONFIG_MODULE_UNLOAD CONFIG_MODULE_SIG
             CONFIG_MODULE_FORCE_LOAD CONFIG_MODULE_FORCE_UNLOAD CONFIG_MODVERSIONS
             CONFIG_KEXEC CONFIG_KEXEC_CORE CONFIG_KEXEC_FILE CONFIG_KEXEC_JUMP
             CONFIG_DEVMEM CONFIG_PROC_KCORE"
must_be_on="CONFIG_SECURITY_LOCKDOWN_LSM CONFIG_SECURITY_LOCKDOWN_LSM_EARLY
            CONFIG_LOCK_DOWN_KERNEL_FORCE_INTEGRITY
            CONFIG_SECURITYFS
            CONFIG_DM_VERITY CONFIG_DM_CRYPT CONFIG_CRYPTO_XTS
            CONFIG_EROFS_FS_ZIP_ZSTD
            CONFIG_TCG_TPM CONFIG_TCG_TIS CONFIG_TCG_CRB CONFIG_HW_RANDOM_TPM
            CONFIG_LD_IS_LLD"
for sym in $must_be_off; do
    got="$(grep -E "^$sym=[ym]" .config || true)"
    if [ -n "$got" ]; then
        echo "ERROR: $got in .config after olddefconfig." >&2
        echo "       The kernel would $sym, which reopens the hole that setting it" >&2
        echo "       to 'n' in $FRAGMENT is what closes. See the comment" >&2
        echo "       above this check for which." >&2
        exit 1
    fi
done
for sym in $must_be_on; do
    if ! grep -qx "$sym=y" .config; then
        echo "ERROR: $sym=y is not in .config after olddefconfig (got:" >&2
        grep -E "^(# )?$sym=|^$sym is not set" .config >&2 || echo "  <symbol absent>" >&2
        echo "       without it part of the boot chain's integrity argument does not" >&2
        echo "       hold, and the kernel boots identically to one with none of it." >&2
        exit 1
    fi
done

# The linker the vmlinux was linked with, from the config rather than from AGENTS.md.
# CONFIG_LD_IS_LLD is a def_bool derived from `ld-version.sh $(LD)'
# (init/Kconfig:55, scripts/Kconfig.include:56), so it reports the linker this build
# actually used and no config file can set it -- which is why it is worth asserting
# here. Passing LD= on the make command line overrides Makefile:526-537's LLVM=1
# assignment (there is no `override LD =' anywhere in the tree, so the command line
# wins), and -fuse-ld=lld is added to KBUILD_HOSTLDFLAGS regardless, because that guard
# filters on KBUILD_HOSTLDFLAGS and not on LD. The result is a kernel whose vmlinux was
# linked by GNU ld while every host tool was linked by lld, and a boot/config that says
# so. A previous build shipped exactly that: CONFIG_LD_IS_BFD=y, CONFIG_LD_VERSION=24000.
lld_version="$(sed -n 's/^CONFIG_LLD_VERSION=//p' .config)"
case "$lld_version" in
    ''|0)
        echo "ERROR: CONFIG_LLD_VERSION=$lld_version with CONFIG_LD_IS_LLD=y." >&2
        echo "       The linker was not detected as lld. Check that ld.lld is on PATH" >&2
        echo "       in the builder (docker/Dockerfile) and that nothing passes LD= to" >&2
        echo "       make; AGENTS.md requires LD=ld.lld." >&2
        exit 1
        ;;
esac

# No `=m' may survive. With CONFIG_MODULES=n, sym_get_type()
# (scripts/kconfig/symbol.c:44-51) reports every tristate as a boolean and the clamp at
# symbol.c:499-500 turns `=m' into `=y', so a module left in the config is built in with
# no diagnostic and no module file -- strictly more attack surface than either of the
# two things it was replaced with. The check is here because kernel.config is a 5500-line
# generated file and this is the one class of mistake in it that olddefconfig reports as
# success.
mods="$(grep -E '^CONFIG_[A-Za-z0-9_]+=m$' .config || true)"
if [ -n "$mods" ]; then
    echo "ERROR: CONFIG_MODULES=n, so every tristate is built in, but these are still '=m':" >&2
    echo "$mods" | sed 's/^/       /' >&2
    echo "       Write them as =y (what gets built) or =n (a real decision)." >&2
    exit 1
fi
echo "kernel integrity config verified: no modules, no kexec, no /dev/mem, no /proc/kcore, lockdown=floor integrity, lld ${lld_version}"

# The actual fix for the i2c-algo-bit duplicate. This is a stale object from an
# incremental build, not a structural one: drivers/i2c/algos/Makefile has exactly one
# reference to i2c-algo-bit.o and there is nothing in the tree that includes it twice.
# It used to be "fixed" by scripts/config --disable CONFIG_I2C_ALGOBIT, which was a
# no-op -- I2C_ALGOBIT is select'ed by seven I2C bus drivers (drivers/i2c/busses/Kconfig
# :312,374,689,1151,1264,1403,1477) so the published config has it =y regardless -- and
# by LD=ld.bfd, which is how a mixed toolchain got in.
rm -f drivers/i2c/algos/built-in.a drivers/i2c/algos/i2c-algo-bit.o drivers/i2c/busses/built-in.a 2>/dev/null || true

# Build with LLVM (clang 17+), incremental. No LD= override: LLVM=1 already sets
# LD=ld.lld (Makefile:526-537) and an explicit LD= would silently beat it, in the linker
# and in the config it records. The linker is asserted to be lld above.
# No `modules' target: CONFIG_MODULES=n (see configs/vngrd.config). There is no module
# loader in this kernel, so `make modules' has nothing to do, and the target would only
# be a place for a stale .o to hide.
# Same one-core-short rule as vngrd-rootfs/config/kiss.conf: saturating the
# box is wrong for a desktop that is also being used. Falls back to
# $(nproc) so running this script outside the harness is unchanged.
make ARCH=x86_64 LLVM=1 -j"${JOBS:-$(( $(nproc) - 1 ))}" bzImage

# Install the kernel (no DEPMOD: there are no modules, and no kmod in the builder)
# Merged /usr: install to /usr/lib/modules (not /lib/modules) so the package is hermetic.
#
# The usr/lib/modules/<kver>/ directory still has to exist even though it is
# empty, because it is how mkosi finds the kernel: mkosi.finalize step 3 copies
# /boot/vmlinuz into each usr/lib/modules/* dir so ukify (UnifiedKernelImages) and
# Bootable=yes can see it, and mkosi's own check_root_populated()/kernel discovery
# looks for usr/lib/modules/<kver>/vmlinuz. `make modules_install' is not relied
# on to create it: with CONFIG_MODULES=n there is no modinst work to do and the
# directory it would have created is an implementation detail of the module
# machinery. Create it explicitly from the same kernelrelease the bzImage reports.
kver="$(make -s ARCH=x86_64 LLVM=1 kernelrelease)"
mkdir -p "/out/usr/lib/modules/$kver"
mkdir -p /out/boot
cp arch/x86/boot/bzImage /out/boot/vmlinuz
cp .config /out/boot/config
echo "Installed kernel $kver (no modules: CONFIG_MODULES=n)"

# Proof that CONFIG_MODULES=n actually took effect. Without it the kernel is
# a perfectly ordinary module-loading kernel that merely ships no modules
# today, and the first thing added to packages/ or a future fragment
# could quietly reintroduce an unsigned module-load path.
if find /out/usr/lib/modules -name '*.ko*' -print -quit | grep -q .; then
    echo "ERROR: a .ko leaked into /out despite CONFIG_MODULES=n" >&2
    find /out/usr/lib/modules -name '*.ko*' >&2
    exit 1
fi
# Ensure no stray top-level /lib remains (hermetic)
if [ -d /out/lib ]; then
    echo "ERROR: /out/lib exists after INSTALL_MOD_PATH=/out/usr — should be /out/usr/lib/modules" >&2
    ls -R /out/lib >&2 || true
    exit 1
fi
