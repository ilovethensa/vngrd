/* pcrdump.c — see pcrdump.h. */

#define _GNU_SOURCE

#include "diagnose.h"
#include "pcrdump.h"

#include <stdio.h>
#include <string.h>

#include <tss2/tss2_esys.h>
#include <tss2/tss2_rc.h>
#include <tss2/tss2_tctildr.h>

int pcrdump(const char *tcti_conf, const int *pcrs, size_t n_pcrs) {
        TSS2_TCTI_CONTEXT *tcti = NULL;
        ESYS_CONTEXT *esys = NULL;
        TSS2_RC rc;
        int ret = 0;

        rc = Tss2_TctiLdr_Initialize(tcti_conf, &tcti);
        if (rc != TSS2_RC_SUCCESS) {
                diagnose("pcrdump: TCTI 0x%08x\n", rc);
                return 1;
        }
        rc = Esys_Initialize(&esys, tcti, NULL);
        if (rc != TSS2_RC_SUCCESS) {
                diagnose("pcrdump: Esys_Initialize 0x%08x\n", rc);
                Tss2_TctiLdr_Finalize(&tcti);
                return 1;
        }

        TPML_DIGEST *digests = NULL;
        TPML_PCR_SELECTION *sel_out = NULL;
        UINT32 update_counter = 0;

        for (size_t i = 0; i < n_pcrs; i++) {
                TPML_PCR_SELECTION sel = {
                        .count = 1,
                        .pcrSelections = { { .hash = TPM2_ALG_SHA256,
                                             .sizeofSelect = 3,
                                             .pcrSelect = { 0, 0, 0 } } },
                };
                unsigned p = (unsigned) pcrs[i];
                sel.pcrSelections[0].pcrSelect[p / 8] = (uint8_t) (1u << (p % 8));

                /* All three sessions ESYS_TR_NONE: PCR_Read authorises no
                 * handle, so a session here is rejected with
                 * TSS2_ESYS_RC_BAD_TR (0x70018, "the ESYS_TR resource object is
                 * bad") before the command is even sent. */
                rc = Esys_PCR_Read(esys, ESYS_TR_NONE, ESYS_TR_NONE, ESYS_TR_NONE,
                                   &sel, &update_counter, &sel_out, &digests);
                if (rc != TSS2_RC_SUCCESS) {
                        diagnose("pcrdump: PCR %d read failed 0x%08x (%s)\n", p, rc,
                                Tss2_RC_Decode(rc) ? Tss2_RC_Decode(rc) : "?");
                        ret = 1;
                        continue;
                }

                /* digests is a bank array; pcrs[i] is its index within the bank. */
                if (digests && (size_t) p < digests->count) {
                        diagnose("PCR %d = ", p);
                        for (int b = 0; b < digests->digests[p].size; b++)
                                diagnose("%02x", digests->digests[p].buffer[b]);
                        diagnose("\n");
                } else {
                        diagnose("pcrdump: PCR %d not in bank (count=%d)\n", p,
                                digests ? digests->count : 0);
                        ret = 1;
                }
                Esys_Free(digests);
                Esys_Free(sel_out);
                digests = NULL;
                sel_out = NULL;
        }

        Esys_Finalize(&esys);
        Tss2_TctiLdr_Finalize(&tcti);
        return ret;
}
