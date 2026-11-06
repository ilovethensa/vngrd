/* fixate.c — read the crypttab, emit the systemd-cryptsetup drop-in. See fixate.h. */

#define _GNU_SOURCE

#include "fixate.h"
#include "diagnose.h"
#include "nvindex.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Hardcode the cryptsetup path rather than reading the generator's output:
 * generators run in parallel, so ordering is not something to rely on. systemd
 * uses bindir/systemd-cryptsetup; mk-initrd-root asserts it is in the initrd. */
#define SYSTEMD_CRYPTSETUP_PATH "/usr/bin/systemd-cryptsetup"

/* Reproduce systemd-cryptsetup-generator's quoting exactly (generator.c:977-981,
 * specifier.c:430-432): single-quote the fields and double '%'. */
static void write_escaped(FILE *f, const char *s) {
        for (const char *p = s; *p != '\0'; p++) {
                if (*p == '%')
                        fputc('%', f);
                fputc(*p, f);
        }
}

static char *dup_or_empty(const char *s) {
        return strdup(s != NULL ? s : "");
}

int fixate_crypttab_lookup(const char *crypttab_path, const char *name, FixateCrypttabEntry *out) {
        if (out == NULL || name == NULL || crypttab_path == NULL)
                return -1;

        memset(out, 0, sizeof(*out));

        FILE *f = fopen(crypttab_path, "re");
        if (f == NULL) {
                diagnose("vngrd-fixate-generator: cannot read %s: %s\n", crypttab_path, strerror(errno));
                return -1;
        }

        char *line = NULL;
        size_t cap = 0;
        ssize_t len;
        int found = 0;

        while ((len = getline(&line, &cap, f)) > 0) {
                if (line[len - 1] == '\n')
                        line[len - 1] = '\0';

                /* Only a leading '#' starts a comment; '#' can occur in options. */
                char *p = line;
                while (*p == ' ' || *p == '\t')
                        p++;
                if (*p == '\0' || *p == '#')
                        continue;

                /* Space-separated fields; a quoted field is rejected rather than
                 * half-parsed. strtok_r needs a mutable buffer. */
                char *fields[4] = { NULL, NULL, NULL, NULL };
                int n = 0;
                char *save = NULL;
                for (char *tok = strtok_r(p, " \t", &save); tok != NULL && n < 4;
                     tok = strtok_r(NULL, " \t", &save)) {
                        if (tok[0] == '"') {
                                fprintf(stderr,
                                        "vngrd-fixate-generator: %s uses a quoted field, which this "
                                        "parser does not implement: %s\n",
                                        crypttab_path, line);
                                free(line);
                                fclose(f);
                                fixate_crypttab_entry_done(out);
                                return -1;
                        }
                        fields[n++] = tok;
                }

                if (n < 1)
                        continue;
                if (strcmp(fields[0], name) != 0)
                        continue;

                out->name = dup_or_empty(fields[0]);
                out->device = dup_or_empty(n > 1 ? fields[1] : NULL);
                out->keyfile = dup_or_empty(n > 2 ? fields[2] : NULL);
                out->options = dup_or_empty(n > 3 ? fields[3] : NULL);

                /* Empty options are valid ("none"), but a line with only a name
                 * would silently drop the device; reject it. */
                if (out->device[0] == '\0') {
                        fprintf(stderr,
                                "vngrd-fixate-generator: %s names %s but gives no device; refusing to "
                                "write a drop-in that would not unlock it\n",
                                crypttab_path, name);
                        free(line);
                        fclose(f);
                        fixate_crypttab_entry_done(out);
                        return -1;
                }

                found = 1;
                break;
        }

        free(line);
        fclose(f);
        return found;
}

void fixate_crypttab_entry_done(FixateCrypttabEntry *entry) {
        if (entry == NULL)
                return;
        free(entry->name);
        free(entry->device);
        free(entry->keyfile);
        free(entry->options);
        memset(entry, 0, sizeof(*entry));
}

/* mkdir -p: systemd creates the generator dirs, but tests and `make run` use
 * paths that do not exist yet. */
static int mkdir_p(const char *path, mode_t mode) {
        char *work = strdup(path);
        if (work == NULL)
                return -ENOMEM;

        int rc = 0;
        for (char *p = work + 1; *p != '\0'; p++) {
                if (*p != '/')
                        continue;
                *p = '\0';
                if (mkdir(work, mode) != 0 && errno != EEXIST) {
                        diagnose("vngrd-fixate-generator: cannot create %s: %s\n",
                                work, strerror(errno));
                        rc = -errno;
                        goto out;
                }
                *p = '/';
        }
        if (mkdir(work, mode) != 0 && errno != EEXIST) {
                diagnose("vngrd-fixate-generator: cannot create %s: %s\n",
                        work, strerror(errno));
                rc = -errno;
        }

out:
        free(work);
        return rc;
}

int fixate_write_dropin(const char *dropin_path,
                        const FixateCrypttabEntry *entry,
                        const char *fixate_hex) {
        if (dropin_path == NULL || entry == NULL || fixate_hex == NULL)
                return -EINVAL;

        if (strlen(fixate_hex) != 2 * VNGRD_FIXATE_DIGEST_LEN) {
                fprintf(stderr,
                        "vngrd-fixate-generator: refusing to write %s: the value is %zu hex digits, "
                        "expected %u\n",
                        dropin_path, strlen(fixate_hex), 2 * VNGRD_FIXATE_DIGEST_LEN);
                return -EINVAL;
        }

        char *dir = strdup(dropin_path);
        if (dir == NULL)
                return -ENOMEM;
        char *slash = strrchr(dir, '/');
        if (slash == NULL) {
                free(dir);
                return -EINVAL;
        }
        *slash = '\0';

        int rc = mkdir_p(dir, 0755);
        free(dir);
        if (rc < 0)
                return rc;

        FILE *f = fopen(dropin_path, "we");
        if (f == NULL) {
                diagnose("vngrd-fixate-generator: cannot write %s: %s\n", dropin_path, strerror(errno));
                return -errno;
        }

        /* Empty ExecStart= first, to reset the vendor list; appending alone
         * leaves two ExecStarts and the unit fails to load. */
        fprintf(f,
                "# Generated by vngrd-fixate-generator. Do not edit.\n"
                "#\n"
                "# Re-runs the cryptsetup attach with fixate-volume-key set, so the volume\n"
                "# key the TPM just released is checked against the digest frozen in NV index\n"
                "# 0x%01X at provisioning. A substituted volume produces a different digest and\n"
                "# is refused before activation. Reproduced from the ExecStart that\n"
                "# systemd-cryptsetup-generator wrote (generator.c:977-981), with the option\n"
                "# appended to the crypttab's own options.\n"
                "[Service]\n"
                "ExecStart=\n"
                "ExecStart=" SYSTEMD_CRYPTSETUP_PATH " attach '",
                VNGRD_NV_INDEX);
        write_escaped(f, entry->name);
        fputs("' '", f);
        write_escaped(f, entry->device);
        fputs("' '", f);
        write_escaped(f, entry->keyfile);
        fputs("' '", f);
        write_escaped(f, entry->options);
        /* Use the separator only when options are present, to avoid a leading
         * comma (a different options list). */
        if (entry->options[0] != '\0')
                fputc(',', f);
        write_escaped(f, "fixate-volume-key=");
        write_escaped(f, fixate_hex);
        fputs("'\n", f);

        if (ferror(f)) {
                diagnose("vngrd-fixate-generator: write to %s failed: %s\n", dropin_path, strerror(errno));
                fclose(f);
                return -EIO;
        }
        if (fclose(f) != 0) {
                diagnose("vngrd-fixate-generator: close of %s failed: %s\n", dropin_path, strerror(errno));
                return -EIO;
        }
        return 0;
}
