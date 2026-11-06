"""Tier 0: the PE reader/writer against a synthetic PE32+."""

from harness import test
from harness import pe

from fixtures.synth import make_pe32plus

SECTIONS = {
    ".linux": b"A" * 0x800,
    ".cmdline": b"usrhash=" + b"ab" * 32 + b" lockdown=integrity",
    ".pcrsig": b'{"sha256": []}',
}
CERT = b"CERTIFICATE-TABLE" * 4


def _image() -> bytes:
    return make_pe32plus(SECTIONS, cert=CERT)


@test(tier="unit", id="pe.sections")
def pe_reads_every_section():
    """Sections are enumerated and read back byte for byte."""
    image = pe.Pe(_image())
    assert image.section_names() == list(SECTIONS), image.section_names()
    for name, payload in SECTIONS.items():
        assert image.section_data(name) == payload, name


@test(tier="unit", id="pe.text")
def pe_decodes_section_text_without_padding():
    """A section's text is NUL-stripped, not padded to the file alignment."""
    image = pe.Pe(_image())
    assert image.section_text(".cmdline").startswith("usrhash=")


@test(tier="unit", id="pe.cert-table")
def pe_finds_and_strips_the_certificate_table():
    """Stripping removes the table and zeroes the directory entry, keeping sections."""
    image = pe.Pe(_image())
    assert image.has_cert_table()
    stripped = image.strip_cert_table()
    assert len(stripped) < len(image.data)
    reparsed = pe.Pe(stripped)
    assert not reparsed.has_cert_table()
    assert reparsed.section_data(".linux") == SECTIONS[".linux"]


@test(tier="unit", id="pe.mutate")
def pe_mutation_changes_exactly_one_byte(tmp):
    """mutate_section writes in place and leaves everything else alone."""
    path = tmp / "test.efi"
    path.write_bytes(_image())
    before = path.read_bytes()
    pe.mutate_section(path, ".linux", 16, b"Z")
    after = path.read_bytes()
    assert after[before.index(b"AAAA") + 16] == ord("Z")
    assert after.count(b"Z") == before.count(b"Z") + 1
    assert len(after) == len(before)


@test(tier="unit", id="pe.bad-image")
def pe_rejects_a_non_pe_buffer():
    """A buffer that is not a PE is an error, not a silently empty parse."""
    try:
        pe.Pe(b"not a pe image" + b"\0" * 64)
    except pe.PeError:
        return
    raise AssertionError("Pe accepted a non-PE buffer")
