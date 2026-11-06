# vngrd-fixate-generator
#
# Flags differ from the generic template because this runs on the target:
#   --sysroot=/out          link against the image's glibc and tpm2-tss
#   --dynamic-linker=...    merged-/usr interpreter; /lib64 is forbidden
#   -rpath,/out/usr/lib     only for `make run` in the builder
# pkg-config finds tss2 so include/lib paths cannot skew.

CC       = clang
PKG_CONFIG = pkg-config
SYSROOT  ?= /out

# tss2-esys: ESAPI calls.
# tss2-tctildr: TCTI loaded by string ("device:/dev/tpmrm0").
# tss2-rc: Tss2_RC_Decode; a bare hex rc is useless on the serial console.
TSS2_PKGS = tss2-esys tss2-tctildr tss2-mu tss2-rc

PKG_CONFIG_SYSROOT_DIR = $(SYSROOT)
PKG_CONFIG_LIBDIR = $(SYSROOT)/usr/lib/pkgconfig:$(SYSROOT)/usr/share/pkgconfig

TSS2_CFLAGS = $(shell $(PKG_CONFIG) --cflags $(TSS2_PKGS))
TSS2_LIBS   = $(shell $(PKG_CONFIG) --libs $(TSS2_PKGS))

WARN = -Wall -Wextra -Wshadow -Wvla -Wpointer-arith -Wwrite-strings \
       -Wformat=2 -Wundef -Wno-unused-parameter

CFLAGS  = -O2 -pipe -march=x86-64 --sysroot=$(SYSROOT) -std=gnu11 \
          -Iinclude $(WARN) $(TSS2_CFLAGS)
LDFLAGS = -fuse-ld=lld --sysroot=$(SYSROOT) \
          -L$(SYSROOT)/usr/lib -L/usr/lib/x86_64-linux-gnu \
          -Wl,--dynamic-linker=/usr/lib/ld-linux-x86-64.so.2 \
          -Wl,-rpath,$(SYSROOT)/usr/lib -Wl,--as-needed

# Two binaries: the generator runs automatically on every boot, so it must not
# be able to write a one-shot register. See src/nvwrite-main.c.
SRC = src/main.c src/fixate.c src/nvindex.c src/diagnose.c
OBJ = $(patsubst src/%.c, build/%.o, $(SRC))
TARGET = build/vngrd-fixate-generator

NVWRITE_SRC = src/nvwrite-main.c src/nvwrite.c
NVWRITE_OBJ = build/nvwrite-main.o build/nvwrite.o
NVWRITE_TARGET = build/vngrd-fixate-nvwrite

# Diagnostic only; prints the PCRs the seal is bound to.
PCR_SRC = src/pcr-main.c src/pcrdump.c
PCR_OBJ = build/pcr-main.o build/pcrdump.o
PCR_TARGET = build/vngrd-fixate-pcr

# Reads two files; diagnose.o keeps failures visible on the console.
CMDLINE_SRC = src/cmdline-main.c src/cmdline.c
CMDLINE_OBJ = build/cmdline-main.o build/cmdline.o
CMDLINE_TARGET = build/vngrd-cmdline-guard

# Guards are read-only; freeze/commit binaries move a one-shot register.
ROLLBACK_SRC = src/rollback.c
ROLLBACK_DEPS = build/rollback.o build/nvindex.o build/nvwrite.o build/diagnose.o build/provisioning.o
ROLLBACK_GUARD_TARGET = build/vngrd-rollback-guard
ROLLBACK_GUARD_OBJ = build/rollback-guard-main.o
ROLLBACK_COMMIT_TARGET = build/vngrd-rollback-commit
ROLLBACK_COMMIT_OBJ = build/rollback-commit-main.o

GPT_OBJ = build/gpt.o build/sha256.o
GPT_GUARD_TARGET = build/vngrd-gpt-guard
GPT_GUARD_OBJ = build/gpt-guard-main.o
GPT_FREEZE_TARGET = build/vngrd-gpt-freeze
GPT_FREEZE_OBJ = build/gpt-freeze-main.o

# Same read/write split as the GPT pair.
ESP_OBJ = build/esp.o build/sha256.o
ESP_GUARD_TARGET = build/vngrd-esp-guard
ESP_GUARD_OBJ = build/esp-guard-main.o
ESP_FREEZE_TARGET = build/vngrd-esp-freeze
ESP_FREEZE_OBJ = build/esp-freeze-main.o

# Read-only, and deliberately not linked with nvwrite.o: a deleted register must
# stay deleted until an operator re-provisions.
FIXATE_GUARD_TARGET = build/vngrd-fixate-guard
FIXATE_GUARD_OBJ = build/fixate-guard-main.o

# Prompts via systemd-ask-password and execs cryptenroll; no TPM access.
PASSPHRASE_SRC = src/passphrase-main.c src/passphrase.c
PASSPHRASE_OBJ = build/passphrase-main.o build/passphrase.o
PASSPHRASE_TARGET = build/vngrd-passphrase

# Host side, after the root is open; libc only. The firmware verifies the loader.
BOOTSYNC_SRC = src/bootsync-main.c src/bootsync.c
BOOTSYNC_OBJ = build/bootsync-main.o build/bootsync.o
BOOTSYNC_TARGET = build/vngrd-bootloader-sync

# Operator-only host tool: a dbx update moves PCR 7 and needs a reseal boot.
# libc only; the firmware verifies the PKCS7 signature.
SECUREBOOT_SRC = src/secureboot-main.c src/secureboot.c
SECUREBOOT_OBJ = build/secureboot-main.o build/secureboot.o
SECUREBOOT_TARGET = build/vngrd-secureboot-update

PREFIX ?= $(SYSROOT)
DESTDIR ?=
# systemd's compile-time generator dir; no env override. Helpers live in
# /usr/lib/vngrd so nothing executes them as generators.
BINDIR   = $(DESTDIR)$(PREFIX)/usr/lib/systemd/system-generators
LIBEXECDIR = $(DESTDIR)$(PREFIX)/usr/lib/vngrd

all: $(TARGET) $(NVWRITE_TARGET) $(PCR_TARGET) $(CMDLINE_TARGET) \
     $(ROLLBACK_GUARD_TARGET) $(ROLLBACK_COMMIT_TARGET) $(GPT_GUARD_TARGET) $(GPT_FREEZE_TARGET) \
     $(ESP_GUARD_TARGET) $(ESP_FREEZE_TARGET) $(FIXATE_GUARD_TARGET) \
     $(BOOTSYNC_TARGET) $(PASSPHRASE_TARGET) $(SECUREBOOT_TARGET)

build/%.o: src/%.c | build
	$(CC) $(CFLAGS) -c $< -o $@

build:
	mkdir -p build

$(TARGET): $(OBJ)
	$(CC) $(OBJ) -o $@ $(LDFLAGS) $(TSS2_LIBS)

# Reads the crypttab in C: /usr/bin/sh is fish and the initrd has no POSIX
# shell. The TPM register, not a marker file, decides whether work remains.
$(NVWRITE_TARGET): $(NVWRITE_OBJ) build/diagnose.o build/fixate.o build/nvindex.o build/provisioning.o
	$(CC) $(NVWRITE_OBJ) build/diagnose.o build/fixate.o build/nvindex.o build/provisioning.o -o $@ $(LDFLAGS) $(TSS2_LIBS)

$(PCR_TARGET): $(PCR_OBJ) build/diagnose.o
	$(CC) $(PCR_OBJ) build/diagnose.o -o $@ $(LDFLAGS) $(TSS2_LIBS)

# No TPM: libc is the only DT_NEEDED.
$(CMDLINE_TARGET): $(CMDLINE_OBJ) build/diagnose.o
	$(CC) $(CMDLINE_OBJ) build/diagnose.o -o $@ $(LDFLAGS)

$(ROLLBACK_GUARD_TARGET): $(ROLLBACK_GUARD_OBJ) $(ROLLBACK_DEPS)
	$(CC) $^ -o $@ $(LDFLAGS) $(TSS2_LIBS)

$(ROLLBACK_COMMIT_TARGET): $(ROLLBACK_COMMIT_OBJ) $(ROLLBACK_DEPS)
	$(CC) $^ -o $@ $(LDFLAGS) $(TSS2_LIBS)

# Guards never link nvwrite.o; the split is the whole point.
$(GPT_GUARD_TARGET): $(GPT_GUARD_OBJ) $(GPT_OBJ) build/nvindex.o build/diagnose.o build/provisioning.o
	$(CC) $^ -o $@ $(LDFLAGS) $(TSS2_LIBS)

$(GPT_FREEZE_TARGET): $(GPT_FREEZE_OBJ) $(GPT_OBJ) build/nvindex.o build/nvwrite.o build/diagnose.o build/provisioning.o
	$(CC) $^ -o $@ $(LDFLAGS) $(TSS2_LIBS)

# Same read/write split as the GPT pair.
$(ESP_GUARD_TARGET): $(ESP_GUARD_OBJ) $(ESP_OBJ) build/nvindex.o build/diagnose.o build/provisioning.o
	$(CC) $^ -o $@ $(LDFLAGS) $(TSS2_LIBS)

$(ESP_FREEZE_TARGET): $(ESP_FREEZE_OBJ) $(ESP_OBJ) build/nvindex.o build/nvwrite.o build/diagnose.o build/provisioning.o
	$(CC) $^ -o $@ $(LDFLAGS) $(TSS2_LIBS)

# Read-only, no nvwrite.o: a deleted register stays deleted until re-provisioning.
$(FIXATE_GUARD_TARGET): $(FIXATE_GUARD_OBJ) build/nvindex.o build/provisioning.o build/diagnose.o
	$(CC) $^ -o $@ $(LDFLAGS) $(TSS2_LIBS)

# Only talks to systemd-ask-password; no TPM.
$(PASSPHRASE_TARGET): $(PASSPHRASE_OBJ)
	$(CC) $^ -o $@ $(LDFLAGS)

# No TPM: a verified file, a vfat write and a read-back.
$(BOOTSYNC_TARGET): $(BOOTSYNC_OBJ) build/sha256.o build/diagnose.o
	$(CC) $^ -o $@ $(LDFLAGS)

# No OpenSSL: the firmware verifies the PKCS7 signature.
$(SECUREBOOT_TARGET): $(SECUREBOOT_OBJ) build/diagnose.o
	$(CC) $^ -o $@ $(LDFLAGS)

# After install: assert the merged-/usr interpreter and that every DT_NEEDED
# resolves inside the sysroot. A link error here is far cheaper than in the initrd.
install: $(TARGET) $(NVWRITE_TARGET) $(PCR_TARGET) $(CMDLINE_TARGET) \
         $(ROLLBACK_GUARD_TARGET) $(ROLLBACK_COMMIT_TARGET) $(GPT_GUARD_TARGET) $(GPT_FREEZE_TARGET) \
         $(ESP_GUARD_TARGET) $(ESP_FREEZE_TARGET) $(FIXATE_GUARD_TARGET) \
         $(BOOTSYNC_TARGET) $(PASSPHRASE_TARGET) $(SECUREBOOT_TARGET)
	mkdir -p $(BINDIR)
	install -m 0755 $(TARGET) $(BINDIR)/vngrd-fixate-generator
	mkdir -p $(LIBEXECDIR)
	install -m 0755 $(NVWRITE_TARGET) $(LIBEXECDIR)/vngrd-fixate-nvwrite
	install -m 0755 $(PCR_TARGET) $(LIBEXECDIR)/vngrd-fixate-pcr
	install -m 0755 $(CMDLINE_TARGET) $(LIBEXECDIR)/vngrd-cmdline-guard
	install -m 0755 $(ROLLBACK_GUARD_TARGET) $(LIBEXECDIR)/vngrd-rollback-guard
	install -m 0755 $(ROLLBACK_COMMIT_TARGET) $(LIBEXECDIR)/vngrd-rollback-commit
	install -m 0755 $(GPT_GUARD_TARGET) $(LIBEXECDIR)/vngrd-gpt-guard
	install -m 0755 $(GPT_FREEZE_TARGET) $(LIBEXECDIR)/vngrd-gpt-freeze
	install -m 0755 $(ESP_GUARD_TARGET) $(LIBEXECDIR)/vngrd-esp-guard
	install -m 0755 $(ESP_FREEZE_TARGET) $(LIBEXECDIR)/vngrd-esp-freeze
	install -m 0755 $(FIXATE_GUARD_TARGET) $(LIBEXECDIR)/vngrd-fixate-guard
	install -m 0755 $(BOOTSYNC_TARGET) $(LIBEXECDIR)/vngrd-bootloader-sync
	install -m 0755 $(PASSPHRASE_TARGET) $(LIBEXECDIR)/vngrd-passphrase
	install -m 0755 $(SECUREBOOT_TARGET) $(LIBEXECDIR)/vngrd-secureboot-update
	@echo "verify: interpreter"
	@readelf -l $(BINDIR)/vngrd-fixate-generator | grep -o '/[a-z0-9/]*ld-linux-x86-64.so.2' \
	    | head -1 | grep -qx '/usr/lib/ld-linux-x86-64.so.2' \
	    || { echo "install: wrong PT_INTERP -- see the LDFLAGS comment"; exit 1; }
	@echo "verify: DT_NEEDED resolves in the sysroot"
	@for bin in $(BINDIR)/vngrd-fixate-generator $(LIBEXECDIR)/vngrd-fixate-nvwrite \
	           $(LIBEXECDIR)/vngrd-fixate-pcr $(LIBEXECDIR)/vngrd-cmdline-guard \
	           $(LIBEXECDIR)/vngrd-rollback-guard $(LIBEXECDIR)/vngrd-rollback-commit \
	           $(LIBEXECDIR)/vngrd-gpt-guard $(LIBEXECDIR)/vngrd-gpt-freeze \
	           $(LIBEXECDIR)/vngrd-esp-guard $(LIBEXECDIR)/vngrd-esp-freeze \
	           $(LIBEXECDIR)/vngrd-fixate-guard $(LIBEXECDIR)/vngrd-bootloader-sync \
	           $(LIBEXECDIR)/vngrd-passphrase $(LIBEXECDIR)/vngrd-secureboot-update; do \
	    for so in $$(readelf -d $$bin | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do \
	        if [ ! -e "$(SYSROOT)$$so" ] && [ ! -e "$(SYSROOT)/usr/lib/$$so" ] \
	           && [ ! -e "$(SYSROOT)/lib/$$so" ]; then \
	            echo "install: $$so (needed by $$bin) does not exist in the sysroot"; exit 1; \
	        fi; \
	    done; \
	done
	@echo "installed $(BINDIR)/vngrd-fixate-generator"
	@echo "installed $(LIBEXECDIR)/vngrd-fixate-nvwrite"
	@echo "installed $(LIBEXECDIR)/vngrd-fixate-pcr"
	@echo "installed $(LIBEXECDIR)/vngrd-cmdline-guard"
	@echo "installed $(LIBEXECDIR)/vngrd-rollback-guard"
	@echo "installed $(LIBEXECDIR)/vngrd-rollback-commit"
	@echo "installed $(LIBEXECDIR)/vngrd-gpt-guard"
	@echo "installed $(LIBEXECDIR)/vngrd-gpt-freeze"
	@echo "installed $(LIBEXECDIR)/vngrd-esp-guard"
	@echo "installed $(LIBEXECDIR)/vngrd-esp-freeze"
	@echo "installed $(LIBEXECDIR)/vngrd-fixate-guard"
	@echo "installed $(LIBEXECDIR)/vngrd-bootloader-sync"
	@echo "installed $(LIBEXECDIR)/vngrd-passphrase"
	@echo "installed $(LIBEXECDIR)/vngrd-secureboot-update"

# Make image binaries runnable in the Debian-based builder, whose loader is at
# /lib64. Same trick as scripts/01-build.sh. No-op if already merged.
ensure-loader:
	@if [ ! -e /usr/lib/ld-linux-x86-64.so.2 ] && [ -e $(SYSROOT)/usr/lib/ld-linux-x86-64.so.2 ]; then \
	    mkdir -p /usr/lib && ln -sf $(SYSROOT)/usr/lib/ld-linux-x86-64.so.2 /usr/lib/ld-linux-x86-64.so.2 \
	    && echo "ensure-loader: linked /usr/lib/ld-linux-x86-64.so.2 -> $(SYSROOT)/usr/lib/..."; \
	fi

# TCTI points at a nonexistent device: the real no-index path, not a mock.
run: $(TARGET) ensure-loader
	$(TARGET) --tcti device:/dev/tpmrm0-nonexistent --verbose; echo "exit=$$?"

# The drop-in writer needs no TPM; a wrong ExecStart means the root never opens.
TEST_TARGET = build/test-dropin
TEST_SRC = tests/test-dropin.c

$(TEST_TARGET): $(TEST_SRC) build/fixate.o build/diagnose.o | build
	$(CC) $(CFLAGS) -Iinclude $(TEST_SRC) build/fixate.o build/diagnose.o -o $@ $(LDFLAGS)

# Two files under /tmp; no TPM or ESP.
TEST_CMDLINE_TARGET = build/test-cmdline
TEST_CMDLINE_SRC = tests/test-cmdline.c

$(TEST_CMDLINE_TARGET): $(TEST_CMDLINE_SRC) build/cmdline.o build/diagnose.o | build
	$(CC) $(CFLAGS) -Iinclude $(TEST_CMDLINE_SRC) build/cmdline.o build/diagnose.o -o $@ $(LDFLAGS)

# NIST vectors. A wrong hash would refuse every provisioned boot.
TEST_SHA_TARGET = build/test-sha256
TEST_SHA_SRC = tests/test-sha256.c

$(TEST_SHA_TARGET): $(TEST_SHA_SRC) build/sha256.o | build
	$(CC) $(CFLAGS) -Iinclude $(TEST_SHA_SRC) build/sha256.o -o $@ $(LDFLAGS)

# Version encoding, including the 0.10 == 1.0 collision. No TPM calls.
TEST_ROLLBACK_TARGET = build/test-rollback
TEST_ROLLBACK_SRC = tests/test-rollback.c

$(TEST_ROLLBACK_TARGET): $(TEST_ROLLBACK_SRC) $(ROLLBACK_DEPS) | build
	$(CC) $(CFLAGS) -Iinclude $(TEST_ROLLBACK_SRC) $(ROLLBACK_DEPS) -o $@ $(LDFLAGS) $(TSS2_LIBS)

# Synthetic GPT in a temp file: which fields move the digest. No TPM.
TEST_GPT_TARGET = build/test-gpt
TEST_GPT_SRC = tests/test-gpt.c

$(TEST_GPT_TARGET): $(TEST_GPT_SRC) $(GPT_OBJ) build/diagnose.o | build
	$(CC) $(CFLAGS) -Iinclude $(TEST_GPT_SRC) $(GPT_OBJ) build/diagnose.o -o $@ $(LDFLAGS)

# Synthetic tree: exclusions and traversal. No ESP, disk or TPM.
TEST_ESP_TARGET = build/test-esp
TEST_ESP_SRC = tests/test-esp.c

$(TEST_ESP_TARGET): $(TEST_ESP_SRC) $(ESP_OBJ) build/diagnose.o | build
	$(CC) $(CFLAGS) -Iinclude $(TEST_ESP_SRC) $(ESP_OBJ) build/diagnose.o -o $@ $(LDFLAGS)

# repart rewrites the crypttab every boot, so only fixate-volume-key= marks
# provisioning; the guards' fail-closed path depends on it.
TEST_PROVISIONING_TARGET = build/test-provisioning
TEST_PROVISIONING_SRC = tests/test-provisioning.c

$(TEST_PROVISIONING_TARGET): $(TEST_PROVISIONING_SRC) build/provisioning.o | build
	$(CC) $(CFLAGS) -Iinclude $(TEST_PROVISIONING_SRC) build/provisioning.o -o $@ $(LDFLAGS)

# Temp dir stands in for the ESP; includes failures that must not look like a
# no-op.
TEST_BOOTSYNC_TARGET = build/test-bootsync
TEST_BOOTSYNC_SRC = tests/test-bootsync.c

$(TEST_BOOTSYNC_TARGET): $(TEST_BOOTSYNC_SRC) build/bootsync.o build/sha256.o build/diagnose.o | build
	$(CC) $(CFLAGS) -Iinclude $(TEST_BOOTSYNC_SRC) build/bootsync.o build/sha256.o build/diagnose.o -o $@ $(LDFLAGS)

# Framing, attributes and the read-back predicate. No efivarfs or firmware.
TEST_SECUREBOOT_TARGET = build/test-secureboot
TEST_SECUREBOOT_SRC = tests/test-secureboot.c

$(TEST_SECUREBOOT_TARGET): $(TEST_SECUREBOOT_SRC) build/secureboot.o build/diagnose.o | build
	$(CC) $(CFLAGS) -Iinclude $(TEST_SECUREBOOT_SRC) build/secureboot.o build/diagnose.o -o $@ $(LDFLAGS)

# Execs the real binary without a TPM; a live-TPM absence is a boot-tier case.
TEST_FIXATE_GUARD_TARGET = build/test-fixate-guard
TEST_FIXATE_GUARD_SRC = tests/test-fixate-guard.c

$(TEST_FIXATE_GUARD_TARGET): $(TEST_FIXATE_GUARD_SRC) $(FIXATE_GUARD_TARGET) | build
	$(CC) $(CFLAGS) $(TEST_FIXATE_GUARD_SRC) -o $@ $(LDFLAGS)

TEST_PASSPHRASE_TARGET = build/test-passphrase
TEST_PASSPHRASE_SRC = tests/test-passphrase.c

$(TEST_PASSPHRASE_TARGET): $(TEST_PASSPHRASE_SRC) build/passphrase.o | build
	$(CC) $(CFLAGS) -Iinclude $(TEST_PASSPHRASE_SRC) build/passphrase.o -o $@ $(LDFLAGS)

test: $(TEST_TARGET) $(TEST_CMDLINE_TARGET) $(TEST_SHA_TARGET) $(TEST_ROLLBACK_TARGET) \
      $(TEST_GPT_TARGET) $(TEST_ESP_TARGET) $(TEST_PROVISIONING_TARGET) \
      $(TEST_BOOTSYNC_TARGET) $(TEST_FIXATE_GUARD_TARGET) $(TEST_PASSPHRASE_TARGET) \
      $(TEST_SECUREBOOT_TARGET) ensure-loader
	./$(TEST_TARGET)
	./$(TEST_CMDLINE_TARGET)
	./$(TEST_SHA_TARGET)
	./$(TEST_ROLLBACK_TARGET)
	./$(TEST_GPT_TARGET)
	./$(TEST_ESP_TARGET)
	./$(TEST_PROVISIONING_TARGET)
	./$(TEST_BOOTSYNC_TARGET)
	./$(TEST_FIXATE_GUARD_TARGET)
	./$(TEST_PASSPHRASE_TARGET)
	./$(TEST_SECUREBOOT_TARGET)

format:
	clang-format -i $(SRC) $(PCR_SRC) $(CMDLINE_SRC) $(ROLLBACK_SRC) $(BOOTSYNC_SRC) \
	    $(SECUREBOOT_SRC) src/gpt.c src/esp.c src/sha256.c src/provisioning.c \
	    $(PASSPHRASE_SRC) src/fixate-guard-main.c $(TEST_SRC) $(TEST_CMDLINE_SRC) \
	    $(TEST_SHA_SRC) $(TEST_ROLLBACK_SRC) $(TEST_GPT_SRC) $(TEST_ESP_SRC) \
	    $(TEST_PROVISIONING_SRC) $(TEST_BOOTSYNC_SRC) $(TEST_FIXATE_GUARD_SRC) \
	    $(TEST_PASSPHRASE_SRC) $(TEST_SECUREBOOT_SRC) include/*.h

tidy:
	clang-tidy $(SRC) $(CMDLINE_SRC) $(ROLLBACK_SRC) $(BOOTSYNC_SRC) $(SECUREBOOT_SRC) \
	    src/gpt.c src/esp.c src/sha256.c src/provisioning.c $(PASSPHRASE_SRC) \
	    src/fixate-guard-main.c -- -Iinclude $(TSS2_CFLAGS)
	clang-tidy $(TEST_CMDLINE_SRC) $(TEST_SHA_SRC) $(TEST_ROLLBACK_SRC) $(TEST_GPT_SRC) \
	    $(TEST_ESP_SRC) $(TEST_PROVISIONING_SRC) $(TEST_BOOTSYNC_SRC) \
	    $(TEST_FIXATE_GUARD_SRC) $(TEST_PASSPHRASE_SRC) $(TEST_SECUREBOOT_SRC) \
	    -- -Iinclude $(TSS2_CFLAGS)

clean:
	rm -rf build

.PHONY: all install run test format tidy clean ensure-loader