/* cmdline.h — compare a kernel command line against the signed one. */

#ifndef VNGRD_CMDLINE_H
#define VNGRD_CMDLINE_H

/* Verify that the command line in live_path is the one in signed_path.
 *
 * Tokens are split on ASCII whitespace and compared by count. Surplus console=
 * tokens are allowed: the stub appends those when the signed line has none
 * (cmdline_append_console(), src/boot/console.c).
 *
 * Returns 0 if equal, 1 if they differ, 2 if a file cannot be read or parsed,
 * the signed line is absent or empty, or the token limit is hit. The signed line
 * is mandatory; absence is a malformed UKI, not a reason to skip the check.
 * *first_difference is set to the first token that disagrees.
 */
int cmdline_verify(const char *signed_path, const char *live_path, const char **first_difference);

#endif /* VNGRD_CMDLINE_H */
