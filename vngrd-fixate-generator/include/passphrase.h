/* passphrase.h — prompt and enrol a recovery passphrase.
 *
 * Used by provisioning and reseal. The secret is only ever typed at the
 * ask-password agent and passed via systemd-cryptenroll's
 * PASSWORD/NEWPASSWORD environment, never written to a file or stdin. No shell:
 * the image has no POSIX shell, and cryptenroll has no --password-file.
 */

#ifndef VNGRD_PASSPHRASE_H
#define VNGRD_PASSPHRASE_H

#include <stdbool.h>
#include <stddef.h>

/* Length only: composition rules produce predictable substitutions. */
#define VNGRD_PASSPHRASE_MIN 16u

/* Hard ceiling including NUL; the prompt is otherwise unbounded. */
#define VNGRD_PASSPHRASE_MAX 1024u

/* NULL when acceptable, else the reason. Four distinct bytes rejects
 * "aaaaaaaaaaaaaaaa"; this is not a dictionary check. */
const char *passphrase_quality_reason(const char *s, size_t min_len);

/* Ask twice, three attempts so a typo does not fail provisioning. Caller owns
 * and must erase *ret. */
int passphrase_prompt_new(char **ret, size_t min_len);

/* No quality check: it was accepted when enrolled, possibly by an older image. */
int passphrase_prompt_current(char **ret);

/* Erase and free; safe on NULL. */
void passphrase_free(char *s);

#endif /* VNGRD_PASSPHRASE_H */
