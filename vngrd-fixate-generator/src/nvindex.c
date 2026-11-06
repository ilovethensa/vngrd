/* nvindex.c — read TPM NV indexes. See nvindex.h.
 *
 * VNGRD_NV_INDEX is already in the OS/vendor range, so it is used as a plain
 * handle; OR'ing TPM2_HR_NV_INDEX again is wrong for other indexes.
 */

#define _GNU_SOURCE

#include "diagnose.h"
#include "nvindex.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <tss2/tss2_esys.h>
#include <tss2/tss2_rc.h>
#include <tss2/tss2_tctildr.h>

/* tss2 4.x removed Tss2_RC_SetLogHandler(), so its stderr diagnostics cannot be
 * redirected. They are useful: outside a TPM they name the missing /dev/tpmrm0.
 */

/* Lowercase hex. Returns -1 if the buffer is too small. */
static int hex_encode(const uint8_t *in, size_t in_len, char *out, size_t out_sz) {
        static const char digits[] = "0123456789abcdef";

        if (out_sz < 2 * in_len + 1)
                return -1;

        for (size_t i = 0; i < in_len; i++) {
                out[2 * i] = digits[in[i] >> 4];
                out[2 * i + 1] = digits[in[i] & 0x0f];
        }
        out[2 * in_len] = '\0';
        return 0;
}

/* The TPM2_RC_* constants are inconsistent about VER1: NV_DEFINED includes it,
 * HANDLE does not, and a real TPM sets it. Mask the layer (bits 16-23) and VER1
 * on both sides; masking only the received value breaks "already defined".
 */
#define VNGRD_RC_MASK (~(TSS2_RC_LAYER_MASK | TPM2_RC_VER1))

/* A real TPM answers 0x18B for an undefined index while TPM2_RC_HANDLE is
 * 0x08B, so the raw codes never match. Normalise both layer and VER1. */

static bool rc_is_missing_index(TSS2_RC rc) {
        TSS2_RC base = rc & ~(TSS2_RC_LAYER_MASK | TPM2_RC_VER1);

        switch (base) {
        case TPM2_RC_NV_DEFINED:
        case TPM2_RC_NV_SPACE:
        case TPM2_RC_HANDLE:
        case TPM2_RC_REFERENCE_H0:
        case TPM2_RC_REFERENCE_H6:
                return true;
        default:
                return false;
        }
}

/* Defined but never written (0x14A). Treat it as zeroes: "absent" would
 * fail open for the GPT digest, while "failed" would refuse the zero-valued
 * counter that is legitimately uninitialised.
 */
static bool rc_is_uninitialized(TSS2_RC rc) {
        return (rc & ~(TSS2_RC_LAYER_MASK | TPM2_RC_VER1)) ==
               (TSS2_RC) (TPM2_RC_NV_UNINITIALIZED & ~(TSS2_RC_LAYER_MASK | TPM2_RC_VER1));
}

/* Decode the rc; callers have already printed the prefix. */
static void append_rc(const char *what, TSS2_RC rc) {
        const char *text = Tss2_RC_Decode(rc);
        diagnose("%s: 0x%08x (%s)", what, rc, text != NULL ? text : "undecodable");
}

NvReadResult nvindex_read_fixate(const char *tcti_conf, char *out_hex, size_t out_hex_sz) {
        TSS2_TCTI_CONTEXT *tcti = NULL;
        ESYS_CONTEXT *esys = NULL;
        TSS2_RC rc;
        NvReadResult result;

        if (tcti_conf == NULL || out_hex == NULL) {
                diagnose("vngrd-fixate-generator: bad arguments\n");
                return NV_READ_FAILED;
        }
        if (out_hex_sz < 2 * VNGRD_FIXATE_DIGEST_LEN + 1) {
                diagnose("vngrd-fixate-generator: output buffer too small\n");
                return NV_READ_FAILED;
        }

        rc = Tss2_TctiLdr_Initialize(tcti_conf, &tcti);
        if (rc != TSS2_RC_SUCCESS) {
                /* No TPM means no expected value; the unseal fails separately. */
                diagnose("vngrd-fixate-generator: TCTI '%s' unavailable, so there is "
                                "no fixate check on this boot. ", tcti_conf);
                append_rc("tctildr", rc);
                return NV_READ_ABSENT;
        }

        rc = Esys_Initialize(&esys, tcti, NULL);
        if (rc != TSS2_RC_SUCCESS) {
                append_rc("Esys_Initialize", rc);
                Tss2_TctiLdr_Finalize(&tcti);
                return NV_READ_FAILED;
        }

        /* NV indices have no fixed ESYS handle, so load the public area. The
         * first argument is the index, not the hierarchy; ESYS_TR_RH_OWNER here
         * gives TPM2_RC_FAILURE. All sessions are ESYS_TR_NONE because
         * ReadPublic takes none -- a password session gives 0x98b, which looks
         * like an undefined index. The owner hierarchy authorises the read below.
         */
        ESYS_TR nv_esys = ESYS_TR_NONE;
        rc = Esys_TR_FromTPMPublic(esys, VNGRD_NV_INDEX, ESYS_TR_NONE, ESYS_TR_NONE,
                                   ESYS_TR_NONE, &nv_esys);
        if (rc != TSS2_RC_SUCCESS) {
                if (rc_is_missing_index(rc)) {
                        result = NV_READ_ABSENT;
                        goto out;
                }
                diagnose("vngrd-fixate-generator: TR_FromTPMPublic for NV index "
                                "0x%08X failed. ", VNGRD_NV_INDEX);
                append_rc("TR_FromTPMPublic", rc);
                result = NV_READ_FAILED;
                goto out;
        }

        /* Use the defined size, not an assumed 32: a truncated value would
         * either fail every boot or compare against a partial expectation.
         * ReadPublic takes no sessions, same as above. */
        TPM2B_NV_PUBLIC *public = NULL;
        TPM2B_NAME *name = NULL;
        rc = Esys_NV_ReadPublic(esys, nv_esys, ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
                                &public, &name);
        if (rc != TSS2_RC_SUCCESS) {
                if (rc_is_missing_index(rc)) {
                        result = NV_READ_ABSENT;
                        goto out;
                }
                append_rc("NV_ReadPublic", rc);
                result = NV_READ_FAILED;
                goto out;
        }

        UINT16 size = public->nvPublic.dataSize;
        Esys_Free(public);
        Esys_Free(name);

        if (size != VNGRD_FIXATE_DIGEST_LEN) {
                fprintf(stderr,
                        "vngrd-fixate-generator: NV index 0x%08X holds %u bytes, expected %u.\n"
                        "  Refusing to use it. A value of the wrong length cannot match the\n"
                        "  fixate digest cryptsetup computes, so the root would never open —\n"
                        "  and a value that DID match would be a different check entirely.\n",
                        VNGRD_NV_INDEX, size, VNGRD_FIXATE_DIGEST_LEN);
                result = NV_READ_FAILED;
                goto out;
        }

        /* OWNERREAD: the owner hierarchy authorises this, which is why it works
         * before the volume is unlocked. */
        TPM2B_MAX_NV_BUFFER *data = NULL;
        rc = Esys_NV_Read(esys, ESYS_TR_RH_OWNER, nv_esys, ESYS_TR_PASSWORD, ESYS_TR_NONE,
                          ESYS_TR_NONE, size, 0, &data);
        if (rc != TSS2_RC_SUCCESS) {
                append_rc("NV_Read", rc);
                result = NV_READ_FAILED;
                goto out;
        }

        if (hex_encode(data->buffer, size, out_hex, out_hex_sz) < 0) {
                diagnose("vngrd-fixate-generator: output buffer too small for %u bytes\n", size);
                Esys_Free(data);
                result = NV_READ_FAILED;
                goto out;
        }
        Esys_Free(data);
        result = NV_READ_OK;

out:
        Esys_Finalize(&esys);
        Tss2_TctiLdr_Finalize(&tcti);
        return result;
}

/* Generic read for the counter and GPT digest. Deliberately a near-copy of the
 * fixate reader so diagnostics can name the register; caller checks the size. */
NvReadResult nvindex_read_raw(const char *tcti_conf, uint32_t index, uint8_t *out,
                              size_t out_cap, size_t *out_got) {
        TSS2_TCTI_CONTEXT *tcti = NULL;
        ESYS_CONTEXT *esys = NULL;
        TSS2_RC rc;
        NvReadResult result;

        if (tcti_conf == NULL || out == NULL || out_got == NULL) {
                diagnose("vngrd-fixate-generator: bad arguments");
                return NV_READ_FAILED;
        }
        *out_got = 0;

        rc = Tss2_TctiLdr_Initialize(tcti_conf, &tcti);
        if (rc != TSS2_RC_SUCCESS) {
                /* Same as above: no TPM, no frozen value to honour. */
                diagnose("vngrd-fixate-generator: TCTI '%s' unavailable, so NV index "
                         "0x%08X cannot be read. ", tcti_conf, index);
                append_rc("tctildr", rc);
                return NV_READ_ABSENT;
        }

        rc = Esys_Initialize(&esys, tcti, NULL);
        if (rc != TSS2_RC_SUCCESS) {
                append_rc("Esys_Initialize", rc);
                Tss2_TctiLdr_Finalize(&tcti);
                return NV_READ_FAILED;
        }

        /* Index, not hierarchy; see nvindex_read_fixate. */
        ESYS_TR nv_esys = ESYS_TR_NONE;
        rc = Esys_TR_FromTPMPublic(esys, index, ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
                                   &nv_esys);
        if (rc != TSS2_RC_SUCCESS) {
                if (rc_is_missing_index(rc)) {
                        result = NV_READ_ABSENT;
                        goto out;
                }
                diagnose("vngrd-fixate-generator: TR_FromTPMPublic for NV index 0x%08X failed. ",
                         index);
                append_rc("TR_FromTPMPublic", rc);
                result = NV_READ_FAILED;
                goto out;
        }

        TPM2B_NV_PUBLIC *public = NULL;
        TPM2B_NAME *name = NULL;
        rc = Esys_NV_ReadPublic(esys, nv_esys, ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
                                &public, &name);
        if (rc != TSS2_RC_SUCCESS) {
                if (rc_is_missing_index(rc)) {
                        result = NV_READ_ABSENT;
                        goto out;
                }
                append_rc("NV_ReadPublic", rc);
                result = NV_READ_FAILED;
                goto out;
        }

        UINT16 size = public->nvPublic.dataSize;
        Esys_Free(public);
        Esys_Free(name);

        if (size == 0 || size > out_cap) {
                diagnose("vngrd-fixate-generator: NV index 0x%08X holds %u bytes, which does not "
                         "fit the %zu-byte buffer the caller has for it", index, size, out_cap);
                result = NV_READ_FAILED;
                goto out;
        }

        TPM2B_MAX_NV_BUFFER *data = NULL;
        rc = Esys_NV_Read(esys, ESYS_TR_RH_OWNER, nv_esys, ESYS_TR_PASSWORD, ESYS_TR_NONE,
                          ESYS_TR_NONE, size, 0, &data);
        if (rc != TSS2_RC_SUCCESS) {
                if (rc_is_uninitialized(rc)) {
                        /* Defined but never written: zeroes. See above. */
                        memset(out, 0, size);
                        *out_got = size;
                        result = NV_READ_OK;
                        goto out;
                }
                append_rc("NV_Read", rc);
                result = NV_READ_FAILED;
                goto out;
        }

        memcpy(out, data->buffer, size);
        *out_got = size;
        Esys_Free(data);
        result = NV_READ_OK;

out:
        Esys_Finalize(&esys);
        Tss2_TctiLdr_Finalize(&tcti);
        return result;
}
