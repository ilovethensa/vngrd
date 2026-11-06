/* test-fixate-guard.c — the decision table for the missing fixate register.
 *
 * No TPM is needed for the cases that matter here: the guard's job is to decide
 * whether it is allowed to skip the check. The one case that must refuse (root
 * present, no provision marker) is exercised with a TCTI device that does not
 * exist, which is the same fail-closed exit as an absent register. The actual
 * absent-index path with a live TPM is covered by the boot tier.
 */

#define _GNU_SOURCE

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define GUARD "./build/vngrd-fixate-guard"

static int failures;

static void write_file(const char *path, const char *text) {
        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
        if (fd < 0) {
                perror(path);
                exit(2);
        }
        size_t len = strlen(text);
        if (write(fd, text, len) != (ssize_t) len) {
                perror(path);
                exit(2);
        }
        close(fd);
}

static int run_guard(const char *marker, const char *root, const char *tcti) {
        pid_t pid = fork();
        if (pid < 0) {
                perror("fork");
                exit(2);
        }
        if (pid == 0) {
                int nullfd = open("/dev/null", O_WRONLY | O_CLOEXEC);
                if (nullfd >= 0) {
                        dup2(nullfd, STDERR_FILENO);
                        close(nullfd);
                }
                execl(GUARD, "vngrd-fixate-guard",
                      "--marker", marker,
                      "--root", root,
                      "--tcti", tcti,
                      (char *) NULL);
                _exit(127);
        }

        int status = 0;
        if (waitpid(pid, &status, 0) < 0) {
                perror("waitpid");
                exit(2);
        }
        if (!WIFEXITED(status))
                return -1;
        return WEXITSTATUS(status);
}

static void expect(int got, int want, const char *what) {
        if (got == want)
                return;
        fprintf(stderr, "test-fixate-guard: FAIL: %s (exit %d, want %d)\n", what, got, want);
        failures++;
}

int main(void) {
        char dir[] = "/tmp/vngrd-fixate-guard-XXXXXX";
        if (mkdtemp(dir) == NULL) {
                perror("mkdtemp");
                return 2;
        }

        char marker[512], root[512], tcti[512];
        snprintf(marker, sizeof(marker), "%s/repart-crypttab", dir);
        snprintf(root, sizeof(root), "%s/vngrd-root", dir);
        snprintf(tcti, sizeof(tcti), "device:%s/no-tpm", dir);

        /* Provisioning boot: repart has written the option and the root node.
         * The index is allowed to be absent because vngrd-fixate.service is
         * about to create it. */
        write_file(marker,
                   "vngrd-root /dev/disk/by-partlabel/vngrd-root none "
                   "luks,fixate-volume-key=00\n");
        write_file(root, "");
        expect(run_guard(marker, root, tcti), 0,
               "provisioning marker permits an absent index even with the root present");

        /* The file exists on every boot. Only the option makes it a marker. */
        write_file(marker,
                   "vngrd-root /dev/disk/by-partlabel/vngrd-root none luks\n");
        expect(run_guard(marker, root, tcti), 1,
               "a crypttab without fixate-volume-key= is not a provisioning marker");

        /* A disk repart has not touched: no root and no marker is not a machine
         * that can have a frozen digest. */
        unlink(root);
        unlink(marker);
        expect(run_guard(marker, root, tcti), 0,
               "an unprovisioned disk with no root partition passes");

        /* A provisioned machine with no marker and no readable TPM must refuse
         * rather than fall through with no volume-key check. */
        write_file(root, "");
        expect(run_guard(marker, root, tcti), 1,
               "a provisioned root with no marker and no TPM refuses");

        /* Marker parsing is content-based: a plain file at the marker path must
         * not turn the refusal into a pass. */
        write_file(marker, "not a crypttab\n");
        expect(run_guard(marker, root, tcti), 1,
               "an empty marker file does not permit a missing register");

        unlink(marker);
        unlink(root);
        rmdir(dir);

        if (failures != 0) {
                fprintf(stderr, "test-fixate-guard: %d failure(s)\n", failures);
                return 1;
        }
        printf("test-fixate-guard: ok\n");
        return 0;
}
