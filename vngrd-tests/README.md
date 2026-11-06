# vngrd-tests

Boot and security tests for vngrd. The suite consumes a built image but is not part of building it, so it can run against a release artefact without the build tree.

The harness is stdlib Python 3.11+. No third-party packages are required.

## Usage

```bash
bin/vngrd-tests list                     # every case, all tiers
bin/vngrd-tests run                      # unit + image (no VM, seconds)
bin/vngrd-tests run --tier boot          # the VM tier
bin/vngrd-tests run --tier boot --case t8-luks2
bin/vngrd-tests run --tier all --junit results/all.xml --json results/all.json
```

Or through `make`:

```bash
make list
make check-host    # unit + image
make check-boot    # qemu + swtpm + OVMF
make check-all
make clean
```

## Tiers

| Tier | Directory | Needs | Runtime |
|---|---|---|---|
| `unit` | `unit/` | nothing | < 1s |
| `image` | `image/` | `output/image` | ~2s |
| `boot` | `boot/` | qemu, swtpm, OVMF, an image | minutes |

`run` defaults to `unit image`. The boot tier is opt-in because it provisions a machine once and needs virtualisation.

## Layout

```
bin/vngrd-tests          entry point
harness/                 runner, fixtures, image/disk/TPM/QEMU helpers
  runner.py              discovery, execution, reporting
  policy.py              security contract parsed from the build config
  context.py             fixture injection
  guest.py               structured boot event stream
unit/ image/ boot/       cases by tier
guest/                   in-image reporter, checks, install.sh
fixtures/                synthetic inputs for unit tests
docs/                    architecture and instrumentation contract
results/                 JUnit and JSON output (gitignored)
```

## Writing a case

A case is a registered function. Its parameter names select fixtures.

```python
from harness import boot_case

@boot_case(id="t8-luks2", timeout=180)
def t8_luks2(vm, report):
    """A broken LUKS2 header must not open the root, but /usr must still mount."""
    boot = vm.start()
    boot.require("tpm.bound")
    boot.require("boot.usr-mounted")
    boot.require("cryptsetup.failed")
    boot.require_absent("boot.root-unsealed")
```

Assertions raise or record a failure; a boot case that records no assertion also fails. Expected posture comes from `policy.*`, parsed from `vngrd-image`, not from literals in the case.

See [docs/architecture.md](docs/architecture.md) and [docs/boot-instrumentation.md](docs/boot-instrumentation.md).

## Environment

| Variable | Meaning |
|---|---|
| `VNGRO_PYTHON` | interpreter for `bin/vngrd-tests` (default `python3`) |
| `VNGRO_REPO` | monorepo root (default: found above this repository) |
| `VNGRO_IMAGE_OUT` | image output directory |
| `VNGRO_TOOLS` | the `mkosi.tools/usr` tree |
| `VNGRO_STATE` | writable state (machines, scratch) |
| `VNGRO_CACHE` | writable cache (decompressed artefacts) |

If the XDG state or cache directories are not writable, the suite uses `.state/` and `.cache/` inside this repository.

## State

```
$VNGRO_STATE/ or .state/
├── machine/            provisioned disk, OVMF vars, swtpm state, identity
├── cases/<case>/       per-case disk, serial log, QEMU stderr, artefacts
└── vngrd/...           run-vm.sh state used during provisioning
```

Provisioning is cached on the image roothash, artefact size/mtime and policy. A rebuild or policy change re-provisions instead of reusing a stale machine.

## Current limits

- The image does not ship the in-guest reporter yet; boot events fall back to documented console anchors.
- Host-side PCR reads are not implemented; PCR state is inferred from the event stream.
- Four cases from the old shell suite are not ported: `t4-wrong-hash`, `t7-enroll-replay`, `t10-pcr11-badsig`, `t16-pcr11-window`.
