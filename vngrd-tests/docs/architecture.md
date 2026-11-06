# Architecture

## Design

The suite is Python, and one case model serves all three tiers. Assertions
raise, so a check that does not run cannot be green. Expected posture comes from
the build's `policy.*` rather than literals repeated in each case. Boot
observation uses structured events instead of console prose, the VM is owned
through QMP, and the harness itself is covered by unit tests.

## Tiers

`unit` has no dependency on a built artefact, so it runs on a bare checkout and
in seconds. `image` reads `output/image` and needs no VM. `boot` is the expensive
tier and is opt-in.

The case model is identical in all three tiers; only the fixtures differ.

## Fixtures

The runner inspects a case function's parameters and injects fixtures by name:

| Fixture | Scope | Provides |
|---|---|---|
| `paths` | session | resolved repository layout |
| `policy` | session | the parsed security contract |
| `image` | session | the built artefact (UKI, GPT, checksums) |
| `tools` | session | external programs, resolved from `mkosi.tools` then PATH |
| `machine` | session | the one provisioned machine |
| `vm` | per case | a cloned disk, seeded state, a `start()` that returns a `Boot` |
| `report` | per case | assertion and artefact recorder |
| `tmp` | per case | a clean scratch directory |

An unknown fixture is a collection error, not a runtime surprise.

## The runner's invariants

`harness/runner.py`:

1. A recorded assertion that is not ok fails the case, even if the function
   returned. This is what makes `report.check()` (non-raising) safe.
2. A boot case with no assertions fails.
3. `xfail` cases that pass are reported as `XPASS` and count as failures, so a
   known-broken case that starts working cannot go unnoticed.
4. Discovery is by import; a case that is not registered is not run, and a
   duplicate id is refused.

## The event stream

`harness/guest.py` defines the contract and two producers. The reporter is the
target; the anchor fallback exists so the suite can be ported before the image
changes. `EventStream.from_log` prefers the reporter and records which producer
was used, so the fallback is visible in results rather than indistinguishable.

## Policy as the single source of truth

`harness/policy.py` merges `mkosi.conf` and `mkosi.conf.d/*`, reads the repart
partition definitions, the effective `systemd-repart` `ExecStart`, and the
`PHASE` constant in the ukify wrapper. `disagreements()` surfaces internal
contradictions, and the image tier fails if the installed drop-in differs from
the parsed contract.

Cases that used to hardcode a PCR set now express either:
- `seal.matches-policy` (the token must equal `policy.pcr_mask`), or
- a conditional on `policy.pcr_mask` (for a case whose expectation depends on
  the decision, such as `t12-gpt-measurement`).

So a change to the seal is a change in one parser and every case follows.

## Deliberate omissions

- No pytest dependency: the runner is self-contained, which suits a hermetic
  project and removes a network dependency from CI.
- No host-side PCR reads yet; the event stream carries what is needed, and
  swtpm's persisted state is the planned upgrade.
- No guest agent or QMP `guest-exec`: it requires `qemu-guest-agent`, which
  this minimal image does not ship. Events are guest-pushed for that reason.
