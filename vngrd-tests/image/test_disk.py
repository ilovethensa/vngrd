"""Tier 1: disk geometry and the ESP.

The partition layout is the contract the boot cases rely on: the verity root
hash names two partition GUIDs, and the ESP is where the UKI lives. Reading it
from the real GPT means a repart change fails here, once, instead of making every
boot case mutate the wrong sector.
"""

from harness import test
from harness.disk import ESP_TYPE_GUID


@test(tier="image", id="disk.esp")
def the_esp_is_the_first_partition_and_correctly_typed(image):
    gpt = image.gpt
    esp = gpt.esp()
    assert esp.type_guid == ESP_TYPE_GUID, esp.type_guid
    assert esp.name == "vngrd-esp", esp.name
    assert esp.first_lba == 2048, "the ESP no longer starts at LBA 2048 (got %d)" % esp.first_lba


@test(tier="image", id="disk.roothash-partuuids")
def the_roothash_halves_name_the_usr_and_verity_partitions(image):
    """usrhash= is literally the two PARTUUIDs, so they must resolve on the disk.

    The old t4 removed the devices the kernel looks for; this checks the
    devices the UKI *names* are the ones that exist.
    """
    gpt = image.gpt
    usrs = [p for p in gpt.partitions if p.name.startswith("vngrd-usr_") and "verity" not in p.name]
    verities = [p for p in gpt.partitions if p.name.startswith("vngrd-usr_") and "verity" in p.name]
    assert usrs, "no vngrd-usr_* data partition: %s" % [p.name for p in gpt.partitions]
    assert verities, "no vngrd-usr_*_verity partition"
    assert usrs[0].unique_guid == image.usr_partuuid, (usrs[0].unique_guid, image.usr_partuuid)
    assert (
        verities[0].unique_guid == image.verity_partuuid
    ), (verities[0].unique_guid, image.verity_partuuid)


@test(tier="image", id="disk.order")
def the_layout_puts_the_data_partition_before_its_verity(image):
    """dm-verity resolves the data device by UUID, but the order is the design."""
    gpt = image.gpt
    esp = gpt.esp()
    usr = next(p for p in gpt.partitions if p.name.startswith("vngrd-usr_") and "verity" not in p.name)
    verity = next(p for p in gpt.partitions if p.name.startswith("vngrd-usr_") and "verity" in p.name)
    assert esp.first_lba < usr.first_lba < verity.first_lba, [esp.first_lba, usr.first_lba, verity.first_lba]


@test(tier="image", id="disk.esp-contents")
def the_esp_carries_the_uki_and_a_production_loader_conf(image, tmp):
    esp = image.esp(tmp / "esp.img")
    path = esp.uki_path()
    assert path.startswith("EFI/Linux/"), path

    loader_conf = esp.get("loader/loader.conf", tmp / "loader.conf").read_text()
    assert "secure-boot-enroll off" in loader_conf, loader_conf
    assert "editor no" in loader_conf, loader_conf
    assert not esp.exists("loader/keys/auto/PK.auth"), (
        "the production image carries enrolment keys on its ESP; setup mode then "
        "lets anything that wrote the ESP replace the platform key before first boot"
    )
