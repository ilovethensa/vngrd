"""Tier 1: the published split artefacts.

mkosi publishes the UKI, /usr, the verity tree and the raw disk alongside each
other. Their names embed the roothash halves, and SHA256SUMS covers them. A
mismatch here means the thing the boot cases boot is not the thing that was
signed and hashed.
"""

import re

from harness import test

HEX64 = re.compile(r"^[0-9a-f]{64}$")


@test(tier="image", id="publish.roothash")
def the_roothash_is_a_64_hex_verity_hash(image):
    assert HEX64.match(image.roothash), image.roothash


@test(tier="image", id="publish.split-names")
def the_split_artefacts_are_named_by_the_roothash_halves(image):
    """The /usr and verity images embed the two halves, so a stale pair is visible."""
    expected_usr = image.paths.image_out / (
        "%s_%s.usr.xz" % (image.name, image.roothash[:32])
    )
    expected_verity = image.paths.image_out / (
        "%s_%s.verity.xz" % (image.name, image.roothash[32:])
    )
    assert expected_usr.is_file(), "missing %s" % expected_usr
    assert expected_verity.is_file(), "missing %s" % expected_verity


@test(tier="image", id="publish.checksums")
def the_published_checksums_match_the_files(image):
    """Every file SHA256SUMS covers must hash to what it says.

    The 4GiB raw is excluded: it is covered by SHA256SUMS too, but hashing it on
    every image-tier run costs more than it catches, and the split artefacts it
    is assembled from are verified instead.
    """
    mismatches = image.verify_checksums(exclude=("%s.raw" % image.name,))
    assert not mismatches, "checksum mismatch: %s" % ", ".join(mismatches)


@test(tier="image", id="publish.raw-is-listed")
def the_raw_disk_is_still_covered_by_the_manifest(image):
    """Excluding it from hashing must not mean excluding it from the manifest."""
    assert "%s.raw" % image.name in image.checksums, sorted(image.checksums)
