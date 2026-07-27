# Phase 3 — mDNS in the test VM

`mdns.t` fails at test 3 (`mdnsd daemon is running`) and `mdns-cleanup.t` dies
at its `mdnsd required` precondition — in both cases after the test's own
`rcctl enable` + `start` + check retry also fails. Provisioning's hardening (set
flags to the default-route interface, enable, restart, verify) passed in the
baseline run, yet `mdnsd` is down by test time.

## What the evidence supports (and rules out)

Everything the two files assert is guest-local: `rcctl check`, `mdnsctl` against
`/var/run/mdnsd.sock`, and `ps` for `mdnsctl publish` children. openhapd
registers by spawning `mdnsctl publish` against that local socket
(`lib/OpenHAP/MDNS.pm`). No assertion requires multicast to leave the guest, so
SLIRP's lack of off-host multicast cannot explain "mdnsd is not running" and is
not this phase's lever. (The harness also has only one network backend, used
locally and in CI alike — if SLIRP were the blocker, this phase's local
acceptance criterion could never hold.)

Ranked hypotheses for 3.1 to discriminate:

1. **`mdnsd` starts, then exits shortly after, every time.** Provisioning's
   verify (`rcctl restart` then an immediate check) is a point-in-time probe
   that can race green. This is the only single cause that fits all three
   observations: the earlier run where the verify itself failed (`d77a9cd`), the
   baseline (verify passed, dead at test time), and the tests' own failed
   restarts.
2. **`mdnsd` is killed or crashes under client churn**: `pkill -9 mdnsctl` at
   suite start, ~20 openhapd restarts before the mDNS files, and `OpenHAP::MDNS`
   kill-and-respawning `mdnsctl publish` on every TXT update. Weakened — not
   excluded — by the failed fresh restarts.
3. **`rcctl check` misreports.** Cheap to eliminate first.

## Tasks

### 3.1 Diagnose at test time, with captured output

- The tests currently discard all rcctl/mdnsd output and die bare. Capture the
  reason: run `mdnsd -d` with output to a file (or start it supervised with
  stderr/syslog recorded) at suite start, and include that plus `rcctl` output
  in the failure diagnostics. Determine which ranked hypothesis holds —
  including whether mdnsd's exit follows its start by a fixed interval (verify
  race) or follows client activity (churn).
- In a local VM, start `mdnsd` by hand on the guest interface, watch its
  lifetime, and run `mdnsctl browse` to observe whether it sees its own
  published services under the guest kernel's multicast loopback.

### 3.2 Fix the in-guest cause

In preference order, based on 3.1:

1. **Lifecycle/config fix**: make `mdnsd` stay up — correct flags/interface
   timing, a settle-then-verify longer than a raced pgrep, rc ordering on
   warm-cache boots (the rc autostart path is never exercised by provisioning,
   which always restarts explicitly).
2. **Client hygiene**, if 3.1 shows churn kills the daemon: withdraw
   registrations gracefully instead of kill/respawn on TXT updates in
   `OpenHAP::MDNS`, and drop the `pkill -9 mdnsctl` from `scripts/integration`.
3. **Network backend change — separately planned last resort**: only if 3.1
   proves an in-guest multicast-loopback deficit (mdnsd cannot hear its own
   answers). This is phase-sized, not a task: every host→guest path assumes
   SLIRP hostfwd to 127.0.0.1 (`lib/OpenHVF/`, both scripts), the installer
   answers `dhcp` against SLIRP's DHCP, the package proxy assumes the `10.0.2.2`
   gateway, macOS development hosts cannot exercise a Linux bridge, and touching
   `.openhvfrc` invalidates both CI caches. If this branch is reached, write a
   new design/plan with abort criteria; do not bolt it onto this phase.

Do **not** add a `skip` to the mDNS tests — `t/openhap/integration/CLAUDE.md`
forbids it, and these files once had SKIP blocks that were deliberately removed.
If mDNS genuinely cannot run, that is a harness capability to provide, not a
test to soften.

### 3.3 Implement and verify

- Apply the chosen fix; confirm `mdnsd` is up and answering `mdnsctl` for the
  duration of both files, and that `mdnsctl browse` sees the `_hap._tcp` service
  `openhapd` registers.

## Deliverables

- Provisioning and/or `OpenHAP::MDNS` and/or harness change with a one-paragraph
  rationale in the commit body (which hypothesis 3.1 confirmed and how).
- Doc updates: `lib/OpenHAP/Test/Integration.pod`'s ENVIRONMENT section gains
  the mdnsd (and mosquitto) prerequisites it currently omits; `INSTALL.md` /
  `man/openhvf/openhvf.1` only if the VM configuration changes.

## Acceptance criteria

- `mdns.t` (12/12) and `mdns-cleanup.t` (6/6) pass in the Integration workflow —
  and the **full suite stays green in suite order**: a running mdnsd makes
  `mdns.t` pair, restart the daemon while paired, and unpair via
  `ensure_unpaired` for the first time, directly upstream of `pairing.t` and
  `tasmota-protocol.t`. (This phase therefore depends on phase 1's
  `ensure_unpaired` fix.)
- Local `make integration` on a developer host (HVF/KVM) passes, with the host,
  accelerator, and result recorded in the PR description.
- `make check` stays green.
