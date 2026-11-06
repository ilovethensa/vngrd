/* test-esp.c — ESP digest over a real temp tree; nothing is mocked.
 *
 * Both halves of the exclusion list matter: including EFI/Linux breaks every
 * sysupdate, and excluding loader.conf or loader/keys hides the tampering this
 * controls. Exclusions are case-insensitive because vfat folds case.
 */

#define _GNU_SOURCE

#include "esp.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;

static void die(const char *what) {
        fprintf(stderr, "test-esp: %s: %s\n", what, strerror(errno));
        exit(1);
}

/* mkdir -p for the baseline. */
static void mkdir_p(const char *path) {
        char work[4096];

        if (snprintf(work, sizeof(work), "%s", path) >= (int) sizeof(work))
                die("path too long");
        for (char *p = work + 1; *p != '\0'; p++) {
                if (*p != '/')
                        continue;
                *p = '\0';
                if (mkdir(work, 0700) != 0 && errno != EEXIST)
                        die("mkdir");
                *p = '/';
        }
        if (mkdir(work, 0700) != 0 && errno != EEXIST)
                die("mkdir");
}

static void write_file(const char *path, const char *content) {
        FILE *f = fopen(path, "we");

        if (f == NULL)
                die(path);
        if (fputs(content, f) == EOF)
                die("fputs");
        fclose(f);
}

/* Fresh tree per case, so mutations cannot leak. */
static char *fresh_tree(void) {
        char tmpl[] = "/tmp/vngrd-test-esp-XXXXXX";
        char *dir = mkdtemp(tmpl);

        if (dir == NULL)
                die("mkdtemp");
        return strdup(dir);
}

static void path_under(const char *root, const char *rel, char *out, size_t out_sz) {
        if (snprintf(out, out_sz, "%s/%s", root, rel) >= (int) out_sz)
                die("path too long");
}

/* Layout measured from the image's FAT32 ESP. */
static void make_baseline(const char *root) {
        char p[4096];

        const char *dirs[] = { "EFI/Linux", "EFI/BOOT", "EFI/SYSTEMD", "loader/entries",
                               "loader/credentials", "loader/keys/AUTO" };
        for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); i++) {
                path_under(root, dirs[i], p, sizeof(p));
                mkdir_p(p);
        }

        path_under(root, "EFI/Linux/vngrd-7.2.7-deadbeef.efi", p, sizeof(p));
        write_file(p, "the unified kernel image");
        path_under(root, "EFI/BOOT/BOOTX64.EFI", p, sizeof(p));
        write_file(p, "sd-boot fallback");
        path_under(root, "EFI/SYSTEMD/systemd-bootx64.efi", p, sizeof(p));
        write_file(p, "sd-boot");
        path_under(root, "loader/loader.conf", p, sizeof(p));
        write_file(p, "default vngrd.conf\ntimeout 3\neditor no\n");
        path_under(root, "loader/entries.srel", p, sizeof(p));
        write_file(p, "vngrd\n");
        path_under(root, "loader/entries/auto.conf", p, sizeof(p));
        write_file(p, "an entry sd-boot synthesised\n");
        path_under(root, "loader/credentials/pcrlock.0123456789abcdef.cred", p, sizeof(p));
        write_file(p, "a per-boot TPM-sealed credential");
        path_under(root, "loader/random-seed", p, sizeof(p));
        write_file(p, "a per-boot random seed\n");
        path_under(root, "loader/keys/AUTO/db.auth", p, sizeof(p));
        write_file(p, "the Secure Boot db enrollment key\n");
        path_under(root, "VMLINUZ", p, sizeof(p));
        write_file(p, "the kernel");
        path_under(root, "CONFIG", p, sizeof(p));
        write_file(p, "the kernel config");
}

static void digest_of(const char *root, uint8_t out[VNGRD_ESP_DIGEST_LEN]) {
        if (esp_digest_tree(root, out) != 0) {
                printf("  FAIL esp_digest_tree returned non-zero for %s\n", root);
                failures++;
                memset(out, 0, VNGRD_ESP_DIGEST_LEN);
        }
}

/* Build baseline, record digest, mutate, assert. */
typedef enum Expect { MUST_CHANGE, MUST_NOT_CHANGE } Expect;

static void case_rewrite(const char *what, Expect want, const char *rel, const char *content) {
        char *root = fresh_tree();
        char p[4096];
        uint8_t base[VNGRD_ESP_DIGEST_LEN], now[VNGRD_ESP_DIGEST_LEN];

        make_baseline(root);
        digest_of(root, base);

        path_under(root, rel, p, sizeof(p));
        write_file(p, content);
        digest_of(root, now);

        int changed = memcmp(base, now, VNGRD_ESP_DIGEST_LEN) != 0;
        if ((want == MUST_CHANGE && changed) || (want == MUST_NOT_CHANGE && !changed))
                printf("  ok   %s\n", what);
        else {
                printf("  FAIL %s (%s)\n", what,
                       changed ? "digest changed, but must not" : "digest did not change, but must");
                failures++;
        }
        free(root);
}

static void case_added_file(const char *what, Expect want, const char *rel) {
        char *root = fresh_tree();
        char p[4096];
        uint8_t base[VNGRD_ESP_DIGEST_LEN], now[VNGRD_ESP_DIGEST_LEN];

        make_baseline(root);
        digest_of(root, base);

        path_under(root, rel, p, sizeof(p));
        /* Create the parent when the case names a nested path. */
        char parent[4096];
        if (snprintf(parent, sizeof(parent), "%s", p) < 0)
                die("snprintf");
        char *slash = strrchr(parent, '/');
        if (slash != NULL) {
                *slash = '\0';
                mkdir_p(parent);
        }
        write_file(p, "a file that was not there before\n");
        digest_of(root, now);

        int changed = memcmp(base, now, VNGRD_ESP_DIGEST_LEN) != 0;
        if ((want == MUST_CHANGE && changed) || (want == MUST_NOT_CHANGE && !changed))
                printf("  ok   %s\n", what);
        else {
                printf("  FAIL %s (%s)\n", what,
                       changed ? "digest changed, but must not" : "digest did not change, but must");
                failures++;
        }
        free(root);
}

static void case_added_dir(const char *what, Expect want, const char *rel) {
        char *root = fresh_tree();
        char p[4096];
        uint8_t base[VNGRD_ESP_DIGEST_LEN], now[VNGRD_ESP_DIGEST_LEN];

        make_baseline(root);
        digest_of(root, base);

        path_under(root, rel, p, sizeof(p));
        if (mkdir(p, 0700) != 0)
                die("mkdir");
        digest_of(root, now);

        int changed = memcmp(base, now, VNGRD_ESP_DIGEST_LEN) != 0;
        if ((want == MUST_CHANGE && changed) || (want == MUST_NOT_CHANGE && !changed))
                printf("  ok   %s\n", what);
        else {
                printf("  FAIL %s (%s)\n", what,
                       changed ? "digest changed, but must not" : "digest did not change, but must");
                failures++;
        }
        free(root);
}

/* Rename tests case folding: on vfat both spellings are the same directory. */
static void case_rename(const char *what, Expect want, const char *from_rel, const char *to_rel) {
        char *root = fresh_tree();
        char from[4096], to[4096];
        uint8_t base[VNGRD_ESP_DIGEST_LEN], now[VNGRD_ESP_DIGEST_LEN];

        make_baseline(root);
        digest_of(root, base);

        path_under(root, from_rel, from, sizeof(from));
        path_under(root, to_rel, to, sizeof(to));
        if (rename(from, to) != 0)
                die("rename");
        digest_of(root, now);

        int changed = memcmp(base, now, VNGRD_ESP_DIGEST_LEN) != 0;
        if ((want == MUST_CHANGE && changed) || (want == MUST_NOT_CHANGE && !changed))
                printf("  ok   %s\n", what);
        else {
                printf("  FAIL %s (%s)\n", what,
                       changed ? "digest changed, but must not" : "digest did not change, but must");
                failures++;
        }
        free(root);
}

/* Creation order must not matter: readdir order is unspecified, the walk sorts. */
static void case_order_independent(void) {
        char *a = fresh_tree();
        char *b = fresh_tree();
        char p[4096];
        uint8_t da[VNGRD_ESP_DIGEST_LEN], db[VNGRD_ESP_DIGEST_LEN];

        make_baseline(a);
        make_baseline(b);

        /* Opposite insertion order on disk. */
        const char *names[] = { "aaa", "bbb", "ccc", "ddd", "eee", "fff" };
        for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
                path_under(b, names[i], p, sizeof(p));
                write_file(p, names[i]);
        }
        for (size_t i = sizeof(names) / sizeof(names[0]); i > 0; i--) {
                path_under(a, names[i - 1], p, sizeof(p));
                write_file(p, names[i - 1]);
        }

        digest_of(a, da);
        digest_of(b, db);

        if (memcmp(da, db, VNGRD_ESP_DIGEST_LEN) == 0)
                printf("  ok   directory entry order does not change the digest\n");
        else {
                printf("  FAIL directory entry order changed the digest\n");
                failures++;
        }
        free(a);
        free(b);
}

/* Empty directories are hashed too, not just files. */
static void case_empty_dir_counts(void) {
        char *root = fresh_tree();
        char p[4096];
        uint8_t base[VNGRD_ESP_DIGEST_LEN], now[VNGRD_ESP_DIGEST_LEN];

        make_baseline(root);
        digest_of(root, base);

        path_under(root, "EFI/weird-empty-dir", p, sizeof(p));
        if (mkdir(p, 0700) != 0)
                die("mkdir");
        digest_of(root, now);

        if (memcmp(base, now, VNGRD_ESP_DIGEST_LEN) != 0)
                printf("  ok   an added empty directory changes the digest\n");
        else {
                printf("  FAIL an added empty directory did not change the digest\n");
                failures++;
        }
        free(root);
}

int main(void) {
        printf("test-esp: ESP identity digest\n");

        /* Loader excluded (updated from verified /usr); loader.conf and keys are not. */
        case_rewrite("sd-boot (fallback path) updated", MUST_NOT_CHANGE,
                     "EFI/BOOT/BOOTX64.EFI", "a newer signed bootloader");
        case_rewrite("sd-boot (systemd path) updated", MUST_NOT_CHANGE,
                     "EFI/SYSTEMD/systemd-bootx64.efi", "a newer signed bootloader");
        case_rewrite("loader.conf edited", MUST_CHANGE, "loader/loader.conf",
                     "default evil.conf\ntimeout 0\neditor yes\n");
        case_rewrite("an enrollment key edited", MUST_CHANGE, "loader/keys/AUTO/db.auth",
                     "a different db");
        case_rewrite("the kernel image edited", MUST_CHANGE, "VMLINUZ", "a different kernel");
        case_added_file("a file added at the root", MUST_CHANGE, "extra.efi");
        case_added_file("a file added under EFI/SYSTEMD", MUST_NOT_CHANGE,
                        "EFI/SYSTEMD/injected.efi");
        case_added_file("a file added under EFI/BOOT", MUST_NOT_CHANGE,
                        "EFI/BOOT/injected.efi");
        case_added_dir("a directory added under EFI", MUST_CHANGE, "EFI/EXTRA");

        /* Excluded: sysupdate tree and per-boot loader state. */
        case_rewrite("a UKI under EFI/Linux rewritten (sysupdate)", MUST_NOT_CHANGE,
                     "EFI/Linux/vngrd-7.2.7-deadbeef.efi", "yesterday's signed UKI");
        case_added_file("a new UKI added under EFI/Linux (sysupdate)", MUST_NOT_CHANGE,
                        "EFI/Linux/vngrd_0.2+3-0.efi");
        case_rewrite("loader/entries.srel rewritten", MUST_NOT_CHANGE, "loader/entries.srel",
                     "somethingelse\n");
        case_rewrite("a loader entry rewritten", MUST_NOT_CHANGE, "loader/entries/auto.conf",
                     "a different entry");
        case_rewrite("the pcrlock credential rewritten (every host boot)", MUST_NOT_CHANGE,
                     "loader/credentials/pcrlock.0123456789abcdef.cred",
                     "a re-minted ciphertext for the same plaintext");
        case_rewrite("the random seed rewritten", MUST_NOT_CHANGE, "loader/random-seed",
                     "a fresh seed\n");

        /* Case change must not move the digest; mkfs.fat may store either case. */
        case_rename("EFI/Linux excluded whatever its case", MUST_NOT_CHANGE, "EFI/Linux",
                    "EFI/linux");
        case_rename("loader/random-seed excluded whatever its case", MUST_NOT_CHANGE,
                    "loader/random-seed", "loader/RANDOM-SEED");

        case_order_independent();
        case_empty_dir_counts();

        if (failures != 0) {
                printf("test-esp: %d FAILED\n", failures);
                return 1;
        }
        printf("test-esp: all cases pass\n");
        return 0;
}
