/* passphrase.c — ask, validate and hand a recovery passphrase to cryptenroll.
 *
 * See passphrase.h for the contract. The only external interface is
 * /usr/bin/systemd-ask-password, the same agent systemd-cryptsetup uses; using it
 * instead of reading /dev/tty directly means the prompt lands on whichever
 * console agent is active (serial in the test harness, the real console on a
 * machine) without this program knowing which one that is.
 */

#define _GNU_SOURCE

#include "passphrase.h"

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define ASK_PASSWORD_PATH "/usr/bin/systemd-ask-password"
#define ASK_PASSWORD_TIMEOUT "600"

const char *passphrase_quality_reason(const char *s, size_t min_len) {
        if (s == NULL || *s == '\0')
                return "the passphrase is empty";
        if (min_len < 1)
                min_len = 1;

        size_t len = strlen(s);
        if (len < min_len)
                return "the passphrase is shorter than the minimum";
        if (len >= VNGRD_PASSPHRASE_MAX)
                return "the passphrase is too long";

        bool non_space = false;
        bool seen[256] = { false };
        size_t distinct = 0;

        for (const unsigned char *p = (const unsigned char *) s; *p != '\0'; p++) {
                if (*p < 0x20 || *p == 0x7f)
                        return "the passphrase contains a control character";

                if (*p != ' ' && *p != '\t')
                        non_space = true;

                if (!seen[*p]) {
                        seen[*p] = true;
                        distinct++;
                }
        }

        if (!non_space)
                return "the passphrase is only whitespace";
        if (distinct < 4)
                return "the passphrase uses fewer than four distinct characters";

        return NULL;
}

static void erase_string(char *s) {
        if (s == NULL)
                return;
        explicit_bzero(s, strlen(s));
}

void passphrase_free(char *s) {
        erase_string(s);
        free(s);
}

/* Inherit the child's stderr so an ask-password failure is visible; stdout is
 * the answer. */
static int ask_password(const char *id, const char *message, char **ret) {
        int fds[2];
        if (pipe2(fds, O_CLOEXEC) < 0) {
                fprintf(stderr, "vngrd-passphrase: pipe2: %s\n", strerror(errno));
                return -1;
        }

        pid_t pid = fork();
        if (pid < 0) {
                fprintf(stderr, "vngrd-passphrase: fork: %s\n", strerror(errno));
                close(fds[0]);
                close(fds[1]);
                return -1;
        }

        if (pid == 0) {
                if (dup2(fds[1], STDOUT_FILENO) < 0)
                        _exit(126);
                close(fds[0]);
                close(fds[1]);
                execl(ASK_PASSWORD_PATH, "systemd-ask-password",
                      "--echo=no",
                      "--timeout=" ASK_PASSWORD_TIMEOUT,
                      "--id", id,
                      "--", message,
                      (char *) NULL);
                _exit(127);
        }

        close(fds[1]);

        char buf[VNGRD_PASSPHRASE_MAX + 2];
        size_t used = 0;
        for (;;) {
                ssize_t n = read(fds[0], buf + used, sizeof(buf) - used - 1);
                if (n < 0) {
                        if (errno == EINTR)
                                continue;
                        fprintf(stderr, "vngrd-passphrase: reading ask-password output: %s\n",
                                strerror(errno));
                        close(fds[0]);
                        explicit_bzero(buf, sizeof(buf));
                        (void) waitpid(pid, NULL, 0);
                        return -1;
                }
                if (n == 0)
                        break;
                used += (size_t) n;
                if (used >= sizeof(buf) - 1) {
                        fprintf(stderr, "vngrd-passphrase: the answer is too long\n");
                        close(fds[0]);
                        explicit_bzero(buf, sizeof(buf));
                        (void) waitpid(pid, NULL, 0);
                        return -1;
                }
        }
        close(fds[0]);

        int status = 0;
        if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
                fprintf(stderr, "vngrd-passphrase: systemd-ask-password failed\n");
                explicit_bzero(buf, sizeof(buf));
                return -1;
        }

        buf[used] = '\0';
        /* Strip only the newline; spaces/tabs are part of the secret. */
        if (used > 0 && buf[used - 1] == '\n') {
                buf[--used] = '\0';
                if (used > 0 && buf[used - 1] == '\r')
                        buf[--used] = '\0';
        }
        if (memchr(buf, '\n', used) != NULL) {
                fprintf(stderr, "vngrd-passphrase: the answer contains more than one line\n");
                explicit_bzero(buf, sizeof(buf));
                return -1;
        }
        if (used == 0) {
                explicit_bzero(buf, sizeof(buf));
                fprintf(stderr, "vngrd-passphrase: the passphrase is empty\n");
                return -1;
        }

        char *answer = strndup(buf, used);
        explicit_bzero(buf, sizeof(buf));
        if (answer == NULL) {
                fprintf(stderr, "vngrd-passphrase: out of memory\n");
                return -1;
        }

        *ret = answer;
        return 0;
}

int passphrase_prompt_new(char **ret, size_t min_len) {
        if (ret == NULL)
                return -1;
        *ret = NULL;

        for (unsigned attempt = 0; attempt < 3; attempt++) {
                char *first = NULL;
                char *second = NULL;

                if (ask_password("vngrd-recovery-passphrase",
                                 "Please enter new passphrase for the root recovery keyslot:",
                                 &first) < 0)
                        return -1;
                if (ask_password("vngrd-recovery-passphrase-repeat",
                                 "Please enter new passphrase (repeat):",
                                 &second) < 0) {
                        passphrase_free(first);
                        return -1;
                }

                if (strcmp(first, second) != 0) {
                        fprintf(stderr,
                                "vngrd-passphrase: the two entries do not match; try again (%u/3)\n",
                                attempt + 1);
                        passphrase_free(first);
                        passphrase_free(second);
                        continue;
                }

                const char *why = passphrase_quality_reason(first, min_len);
                if (why != NULL) {
                        fprintf(stderr,
                                "vngrd-passphrase: %s; at least %zu characters are required. "
                                "A long diceware phrase is easier to remember and stronger. "
                                "Try again (%u/3)\n",
                                why, min_len, attempt + 1);
                        passphrase_free(first);
                        passphrase_free(second);
                        continue;
                }

                passphrase_free(second);
                *ret = first;
                return 0;
        }

        fprintf(stderr, "vngrd-passphrase: no acceptable passphrase after three attempts\n");
        return -1;
}

int passphrase_prompt_current(char **ret) {
        if (ret == NULL)
                return -1;
        *ret = NULL;

        char *value = NULL;
        if (ask_password("vngrd-current-recovery-passphrase",
                         "Please enter current recovery passphrase:",
                         &value) < 0)
                return -1;

        if (strlen(value) >= VNGRD_PASSPHRASE_MAX) {
                fprintf(stderr, "vngrd-passphrase: the passphrase is too long\n");
                passphrase_free(value);
                return -1;
        }

        *ret = value;
        return 0;
}
