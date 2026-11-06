/* diagnose.c — report hard failures on /dev/console as well as stderr.
 *
 * The initrd has no working journal and systemd reduces a failed generator to
 * "failed with exit status 1", with no TPM or index detail. Only hard failures go
 * to the console: the normal no-index case must stay silent, or the line becomes
 * noise on every boot.
 */

#define _GNU_SOURCE

#include "diagnose.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

void diagnose(const char *fmt, ...) {
        char buf[1024];
        va_list ap;

        va_start(ap, fmt);
        int n = vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        if (n < 0)
                return;

        fprintf(stderr, "%s\n", buf);
        fflush(stderr);

        /* Best effort; the caller owns the exit status. */
        int fd = open("/dev/console", O_WRONLY | O_CLOEXEC | O_NOCTTY);
        if (fd < 0)
                return;

        /* One write; the tty layer serialises. No O_APPEND: this is not a file. */
        ssize_t written = write(fd, buf, (size_t) n);
        if (written > 0) {
            const char nl = '\n';
            (void) write(fd, &nl, 1);
        }
        close(fd);
}
