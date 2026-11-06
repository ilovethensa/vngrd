/* nvwrite.c — see nvwrite.h. */

#define _GNU_SOURCE

#include "nvwrite.h"

#include "diagnose.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <inttypes.h>

#include <tss2/tss2_esys.h>
#include <tss2/tss2_rc.h>
#include <tss2/tss2_tctildr.h>

static int hex_nibble(char c) {
        if (c >= '0' && c <= '9')
                return c - '0';
        if (c >= 'a' && c <= 'f')
                return c - 'a' + 10;
        if (c >= 'A' && c <= 'F')
                return c - 'A' + 10;
        return -1;
}

/* Decode exactly n bytes out of a 2n-character hex string. */
static bool hex_decode(const char *hex, uint8_t *out, size_t n) {
        for (size_t i = 0; i < n; i++) {
                int hi = hex_nibble(hex[2 * i]);
                int lo = hex_nibble(hex[2 * i + 1]);
                if (hi < 0 || lo < 0)
                        return false;
                out[i] = (uint8_t) ((hi << 4) | lo);
        }
        return true;
}

/* Same VER1/layer inconsistency as nvindex.c: mask both sides. */
#define VNGRD_RC_MASK (~(TSS2_RC_LAYER_MASK | TPM2_RC_VER1))

/* The same masking trap as nvindex.c. */
static bool rc_is_already_defined(TSS2_RC rc) {
        TSS2_RC base = rc & VNGRD_RC_MASK;

        return base == (TSS2_RC) (TPM2_RC_NV_DEFINED & VNGRD_RC_MASK) ||
               base == (TSS2_RC) (TPM2_RC_NV_SPACE & VNGRD_RC_MASK) ||
               base == (TSS2_RC) (TPM2_RC_HANDLE & VNGRD_RC_MASK) ||
               base == (TSS2_RC) (TPM2_RC_REFERENCE_H0 & VNGRD_RC_MASK) ||
               base == (TSS2_RC) (TPM2_RC_REFERENCE_H6 & VNGRD_RC_MASK);
}

/* Defined but never incremented: the spec value is zero. Treating this as an
 * error would refuse the floor forever after a power loss between define and
 * increment. */
static bool rc_is_uninitialized(TSS2_RC rc) {
        return (rc & VNGRD_RC_MASK) == (TSS2_RC) (TPM2_RC_NV_UNINITIALIZED & VNGRD_RC_MASK);
}

static void report(const char *what, TSS2_RC rc) {
        const char *text = Tss2_RC_Decode(rc);
        diagnose("vngrd-fixate-nvwrite: %s: 0x%08x (%s)", what, rc,
                 text != NULL ? text : "undecodable");
}

/* Define, write and lock one value; the one-shot guarantee must be identical
 * for the fixate and GPT digests. */
static NvWriteResult freeze_bytes(const char *tcti_conf, const uint8_t *data, size_t len,
                                  uint32_t index, TPMA_NV attrs) {

        TSS2_TCTI_CONTEXT *tcti = NULL;
        ESYS_CONTEXT *esys = NULL;
        TSS2_RC rc;
        NvWriteResult result = NV_WRITE_FAILED;

        rc = Tss2_TctiLdr_Initialize(tcti_conf, &tcti);
        if (rc != TSS2_RC_SUCCESS) {
                diagnose("vngrd-fixate-nvwrite: TCTI '%s' unavailable. ", tcti_conf);
                report("tctildr", rc);
                return NV_WRITE_FAILED;
        }

        rc = Esys_Initialize(&esys, tcti, NULL);
        if (rc != TSS2_RC_SUCCESS) {
                report("Esys_Initialize", rc);
                Tss2_TctiLdr_Finalize(&tcti);
                return NV_WRITE_FAILED;
        }

        /* .size is the TPMS_NV_PUBLIC payload size, not the struct size. ESAPI
         * passes it to Unmarshal; zero fails with a bare BAD_VALUE. */
        TPM2B_NV_PUBLIC public = {
                .size = sizeof(TPMS_NV_PUBLIC),
                .nvPublic = {
                        .nvIndex = index,
                        .nameAlg = TPM2_ALG_SHA256,
                        .attributes = attrs,
                        .dataSize = (UINT16) len,
                },
        };

        /* ESYS_TR_PASSWORD is required even with an empty password; ESYS_TR_NONE
         * fails session feasibility before reaching the TPM. */
        TPM2B_AUTH empty_auth = { .size = 0 };
        ESYS_TR nv_handle = ESYS_TR_NONE;

        rc = Esys_NV_DefineSpace(esys, ESYS_TR_RH_OWNER, ESYS_TR_PASSWORD, ESYS_TR_NONE,
                                 ESYS_TR_NONE, &empty_auth, &public, &nv_handle);
        if (rc != TSS2_RC_SUCCESS) {
                if (rc_is_already_defined(rc)) {
                        /* Already frozen: the normal state after first boot. */
                        result = NV_WRITE_ALREADY_PRESENT;
                        goto out;
                }
                diagnose("vngrd-fixate-nvwrite: NV_DefineSpace(0x%08x) failed. ", index);
                report("NV_DefineSpace", rc);
                result = NV_WRITE_FAILED;
                goto out;
        }

        /* buffer is a fixed array, so copy into it. */
        TPM2B_MAX_NV_BUFFER buffer = { .size = 0, .buffer = { 0 } };
        memcpy(buffer.buffer, data, len);
        buffer.size = (UINT16) len;

        rc = Esys_NV_Write(esys, ESYS_TR_RH_OWNER, nv_handle, ESYS_TR_PASSWORD, ESYS_TR_NONE,
                           ESYS_TR_NONE, &buffer, 0);
        if (rc != TSS2_RC_SUCCESS) {
                report("NV_Write", rc);
                result = NV_WRITE_FAILED;
                goto out;
        }

        /* WRITEDEFINE makes this lock permanent; without it the index becomes
         * writable again after the next TPM reset. */
        rc = Esys_NV_WriteLock(esys, ESYS_TR_RH_OWNER, nv_handle, ESYS_TR_PASSWORD,
                               ESYS_TR_NONE, ESYS_TR_NONE);
        if (rc != TSS2_RC_SUCCESS) {
                /* The value is stored but rewritable; say so distinctly. */
                diagnose("vngrd-fixate-nvwrite: the digest is stored, but NV_WriteLock failed, so "
                         "the index is NOT permanently write-locked and could be rewritten. ");
                report("NV_WriteLock", rc);
                result = NV_WRITE_FAILED;
                goto out;
        }

        result = NV_WRITE_OK;

out:
        Esys_Finalize(&esys);
        Tss2_TctiLdr_Finalize(&tcti);
        return result;
}

NvWriteResult nvwrite_freeze(const char *tcti_conf, const char *fixate_hex, uint32_t index) {
        uint8_t digest[VNGRD_FIXATE_DIGEST_LEN];

        if (tcti_conf == NULL || fixate_hex == NULL) {
                diagnose("vngrd-fixate-nvwrite: bad arguments");
                return NV_WRITE_FAILED;
        }
        if (strlen(fixate_hex) != 2 * VNGRD_FIXATE_DIGEST_LEN) {
                diagnose("vngrd-fixate-nvwrite: the digest is %zu hex characters, expected %u. "
                         "Refusing: a value of the wrong length cannot match what cryptsetup "
                         "computes, so it would refuse every boot rather than protect one.",
                         strlen(fixate_hex), 2 * VNGRD_FIXATE_DIGEST_LEN);
                return NV_WRITE_FAILED;
        }
        if (!hex_decode(fixate_hex, digest, sizeof(digest))) {
                diagnose("vngrd-fixate-nvwrite: the digest is not hex");
                return NV_WRITE_FAILED;
        }

        return freeze_bytes(tcti_conf, digest, sizeof(digest), index, VNGRD_NV_ATTRS);
}

/* Raw values are digest-sized; 64 is already a caller bug. */
#define VNGRD_MAX_RAW_NV 64u

NvWriteResult nvwrite_freeze_raw(const char *tcti_conf, const uint8_t *data, size_t len,
                                 uint32_t index) {
        if (tcti_conf == NULL || data == NULL) {
                diagnose("vngrd-fixate-nvwrite: bad arguments");
                return NV_WRITE_FAILED;
        }
        if (len == 0 || len > VNGRD_MAX_RAW_NV) {
                diagnose("vngrd-fixate-nvwrite: refusing to freeze %zu bytes into NV index "
                         "0x%08X; the raw writer is for a digest-sized value",
                         len, index);
                return NV_WRITE_FAILED;
        }

        return freeze_bytes(tcti_conf, data, len, index, VNGRD_NV_ATTRS);
}

NvWriteResult nvwrite_counter_ensure(const char *tcti_conf, uint32_t index, uint64_t target,
                                     bool create) {
        TSS2_TCTI_CONTEXT *tcti = NULL;
        ESYS_CONTEXT *esys = NULL;
        TSS2_RC rc;
        NvWriteResult result = NV_WRITE_FAILED;

        if (tcti_conf == NULL) {
                diagnose("vngrd-fixate-nvwrite: bad arguments");
                return NV_WRITE_FAILED;
        }

        rc = Tss2_TctiLdr_Initialize(tcti_conf, &tcti);
        if (rc != TSS2_RC_SUCCESS) {
                diagnose("vngrd-fixate-nvwrite: TCTI '%s' unavailable. ", tcti_conf);
                report("tctildr", rc);
                return NV_WRITE_FAILED;
        }

        rc = Esys_Initialize(&esys, tcti, NULL);
        if (rc != TSS2_RC_SUCCESS) {
                report("Esys_Initialize", rc);
                Tss2_TctiLdr_Finalize(&tcti);
                return NV_WRITE_FAILED;
        }

        /* create=false must never define the floor: a running image would pick
         * its own version. A counter's size is fixed at 8 and the type bits live
         * in VNGRD_NV_COUNTER_ATTRS; without them NV_Increment fails. */
        if (create) {
                TPM2B_NV_PUBLIC public = {
                        .size = sizeof(TPMS_NV_PUBLIC),
                        .nvPublic = {
                                .nvIndex = index,
                                .nameAlg = TPM2_ALG_SHA256,
                                .attributes = VNGRD_NV_COUNTER_ATTRS,
                                .dataSize = 8,
                        },
                };
                TPM2B_AUTH empty_auth = { .size = 0 };
                ESYS_TR nv_handle = ESYS_TR_NONE;

                rc = Esys_NV_DefineSpace(esys, ESYS_TR_RH_OWNER, ESYS_TR_PASSWORD, ESYS_TR_NONE,
                                         ESYS_TR_NONE, &empty_auth, &public, &nv_handle);
                if (rc != TSS2_RC_SUCCESS && !rc_is_already_defined(rc)) {
                        diagnose("vngrd-fixate-nvwrite: NV_DefineSpace(0x%08x) for the rollback "
                                 "counter failed. ", index);
                        report("NV_DefineSpace", rc);
                        result = NV_WRITE_FAILED;
                        goto out;
                }
        }

        /* Load the handle for both paths: increment and read need it. */
        ESYS_TR nv_esys = ESYS_TR_NONE;
        rc = Esys_TR_FromTPMPublic(esys, index, ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
                                   &nv_esys);
        if (rc != TSS2_RC_SUCCESS) {
                if (!create)
                        diagnose("vngrd-fixate-nvwrite: rollback counter 0x%08x is absent and "
                                 "creation is not permitted on this boot. A running image must "
                                 "never define the floor it is about to be measured against. ",
                                 index);
                report("TR_FromTPMPublic", rc);
                result = NV_WRITE_FAILED;
                goto out;
        }

        uint64_t current;
        {
                TPM2B_MAX_NV_BUFFER *value = NULL;
                rc = Esys_NV_Read(esys, ESYS_TR_RH_OWNER, nv_esys, ESYS_TR_PASSWORD,
                                  ESYS_TR_NONE, ESYS_TR_NONE, 8, 0, &value);
                if (rc == TSS2_RC_SUCCESS) {
                        current = 0;
                        for (unsigned i = 0; i < 8; i++)   /* a counter is big-endian */
                                current = (current << 8) | value->buffer[i];
                        Esys_Free(value);
                } else if (rc_is_uninitialized(rc)) {
                        /* Defined but never incremented: value 0; the increments
                         * below initialise it. */
                        current = 0;
                } else {
                        report("NV_Read", rc);
                        result = NV_WRITE_FAILED;
                        goto out;
                }
        }

        if (current >= target) {
                /* Normal case after the first commit. */
                result = NV_WRITE_OK;
                goto out;
        }

        /* A counter moves one step per command; adjacent releases are ten apart,
         * so this is a handful of writes per update. */
        for (uint64_t i = 0; i < target - current; i++) {
                rc = Esys_NV_Increment(esys, ESYS_TR_RH_OWNER, nv_esys, ESYS_TR_PASSWORD,
                                       ESYS_TR_NONE, ESYS_TR_NONE);
                if (rc != TSS2_RC_SUCCESS) {
                        diagnose("vngrd-fixate-nvwrite: the rollback counter reached %" PRIu64
                                 " of %" PRIu64 " before NV_Increment failed; the floor is "
                                 "lower than this boot's version, which is the safe direction",
                                 current + i, target);
                        report("NV_Increment", rc);
                        result = NV_WRITE_FAILED;
                        goto out;
                }
        }

        result = NV_WRITE_OK;

out:
        Esys_Finalize(&esys);
        Tss2_TctiLdr_Finalize(&tcti);
        return result;
}
