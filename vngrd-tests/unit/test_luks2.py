"""Tier 0: LUKS2 header reading against a synthetic container."""

from harness import luks2, test

from fixtures.synth import default_tpm2_document, make_luks2


@test(tier="unit", id="luks2.decode")
def luks2_decodes_a_well_formed_header(tmp):
    path = tmp / "luks2.img"
    path.write_bytes(make_luks2(default_tpm2_document()))
    document = luks2.header_at(path, 0)
    assert "tokens" in document and "keyslots" in document


@test(tier="unit", id="luks2.token-fields")
def luks2_reads_the_tpm2_token_and_its_fields(tmp):
    path = tmp / "luks2.img"
    path.write_bytes(make_luks2(default_tpm2_document()))
    document = luks2.header_at(path, 0)
    token = luks2.tpm2_token(document)
    assert token is not None and token["type"] == "systemd-tpm2"
    assert luks2.field(document, "tpm2-pcrs") == [7]
    assert luks2.field(document, "tpm2_pubkey_pcrs") == [11]
    assert luks2.field(document, "missing") is None


@test(tier="unit", id="luks2.keyslots")
def luks2_reports_keyslot_types_and_recovery(tmp):
    path = tmp / "luks2.img"
    path.write_bytes(make_luks2(default_tpm2_document()))
    document = luks2.header_at(path, 0)
    # Both keyslots are ordinary luks2 ones -- systemd-recovery is a token type,
    # not a keyslot type -- and the recovery is identified by its token, which is
    # what has_recovery looks for.
    assert luks2.keyslot_types(document) == ["luks2", "luks2"]
    assert luks2.has_recovery(document)


@test(tier="unit", id="luks2.bad-magic")
def luks2_rejects_a_header_with_the_wrong_magic():
    try:
        luks2.decode(b"NOPE" + b"\0" * 8192)
    except luks2.Luks2Error:
        return
    raise AssertionError("decode accepted a non-LUKS2 buffer")


@test(tier="unit", id="luks2.secondary-header")
def luks2_requires_the_secondary_header(tmp):
    """A truncated read must fail: cryptsetup can recover from the SKUL copy."""
    path = tmp / "truncated.img"
    data = make_luks2(default_tpm2_document())
    path.write_bytes(data[: len(data) - 4])
    try:
        luks2.header_at(path, 0)
    except luks2.Luks2Error:
        return
    raise AssertionError("decode accepted a header with no secondary magic")
