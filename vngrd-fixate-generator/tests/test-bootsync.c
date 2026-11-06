/* test-bootsync.c — the copy/verify half of the host sd-boot update.
 *
 * No ESP and no mount: bootsync_tree() takes a directory, so the cases that
 * matter are ordinary files under mkdtemp. The failure this is written against is
 * a "successful" update that wrote one path and not the other, or replaced a
 * working loader with a half-written file.
 *
 * Build: make test
 */

#define _GNU_SOURCE

#include "bootsync.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;

static void die(const char *what) {
        fprintf(stderr, "test-bootsync: %s: %s\n", what, strerror(errno));
        exit(1);
}

static char *fresh_dir(void) {
        char tmpl[] = "/tmp/vngrd-test-bootsync-XXXXXX";
        char *d = mkdtemp(tmpl);

        if (d == NULL)
                die("mkdtemp");
        return strdup(d);
}

static void write_file(const char *path, const char *content) {
        FILE *f = fopen(path, "we");

        if (f == NULL)
                die(path);
        if (fputs(content, f) == EOF)
                die("fputs");
        fclose(f);
}

static int same_content(const char *path, const char *want) {
        FILE *f = fopen(path, "re");
        char buf[4096];
        size_t n;

        if (f == NULL)
                return 0;
        n = fread(buf, 1, sizeof(buf), f);
        fclose(f);
        return n == strlen(want) && memcmp(buf, want, n) == 0;
}

static void join(char *dst, size_t dst_sz, const char *a, const char *b) {
        if (snprintf(dst, dst_sz, "%s/%s", a, b) >= (int) dst_sz)
                die("path too long");
}

static void expect_case(const char *what, int ok) {
        if (ok) {
                printf("  ok   %s\n", what);
        } else {
                printf("  FAIL %s\n", what);
                failures++;
        }
}

int main(void) {
        printf("test-bootsync: signed loader copy\n");

        char *root = fresh_dir();
        char source[4096], esp[4096], a[4096], b[4096];
        join(source, sizeof(source), root, "systemd-bootx64.efi.signed");
        join(esp, sizeof(esp), root, "esp");

        if (mkdir(esp, 0700) != 0)
                die("mkdir esp");

        write_file(source, "signed sd-boot version one");
        expect_case("first sync succeeds", bootsync_tree(source, esp) == 0);
        join(a, sizeof(a), esp, "EFI/systemd/systemd-bootx64.efi");
        join(b, sizeof(b), esp, "EFI/BOOT/BOOTX64.EFI");
        expect_case("EFI/systemd copy has the source bytes",
                    same_content(a, "signed sd-boot version one"));
        expect_case("fallback copy has the source bytes",
                    same_content(b, "signed sd-boot version one"));

        struct stat before, after;
        if (stat(a, &before) != 0)
                die("stat a");
        expect_case("second sync succeeds", bootsync_tree(source, esp) == 0);
        if (stat(a, &after) != 0)
                die("stat a");
        expect_case("an up-to-date file is not rewritten", before.st_ino == after.st_ino);

        write_file(source, "signed sd-boot version two");
        expect_case("update sync succeeds", bootsync_tree(source, esp) == 0);
        expect_case("systemd path updated", same_content(a, "signed sd-boot version two"));
        expect_case("fallback updated", same_content(b, "signed sd-boot version two"));

        write_file(a, "a disk-only attacker wrote this");
        expect_case("repair sync succeeds", bootsync_tree(source, esp) == 0);
        expect_case("tampered systemd path restored",
                    same_content(a, "signed sd-boot version two"));
        expect_case("untouched fallback remains correct",
                    same_content(b, "signed sd-boot version two"));

        /* A directory where the loader should be must fail, not be renamed over. */
        if (unlink(b) != 0)
                die("unlink b");
        if (mkdir(b, 0700) != 0)
                die("mkdir b");
        expect_case("a directory at the target is refused", bootsync_tree(source, esp) != 0);

        /* O_NOFOLLOW: a symlink source is not a signed artifact. */
        char link[4096];
        join(link, sizeof(link), root, "link.efi");
        if (symlink(source, link) != 0)
                die("symlink");
        expect_case("a symlink source is refused", bootsync_tree(link, esp) != 0);

        char missing[4096];
        join(missing, sizeof(missing), root, "missing.efi");
        expect_case("a missing source is refused", bootsync_tree(missing, esp) != 0);

        if (failures != 0) {
                printf("test-bootsync: %d failure(s)\n", failures);
                return 1;
        }
        printf("test-bootsync: all cases pass\n");
        return 0;
}
