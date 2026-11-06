"""Tier 2: dm-verity is load-bearing.

Corrupting one block of the /usr data partition must stop the boot, even though
the partition table, the UKI and the TPM are all untouched. This is the case
that proves the usrhash= inside the signed command line is what the kernel
trusts.
"""

from harness import boot_case


@boot_case(id="t2-usr", timeout=150)
def t2_usr(vm, report):
    """Four bytes of /usr block 0: verity must reject and the initrd must not continue."""
    usr = next(
        p for p in vm.gpt.partitions if p.name.startswith("vngrd-usr_") and "verity" not in p.name
    )
    # Four bytes, not one: dm-verity's block size is 4096, and block 0 is not a
    # superblock, so this damages verity, not erofs.
    vm.poke(usr.offset, b"\xde\xad\xbe\xef")

    boot = vm.start()
    boot.require("verity.corrupt")
    boot.require("verity.mount-failed")
    boot.require_absent("boot.login-ready")
    boot.require_absent("boot.multi-user")
