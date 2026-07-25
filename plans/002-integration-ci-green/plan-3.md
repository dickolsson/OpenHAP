# Phase 3 — mDNS under emulated networking

`mdns.t` fails at subtest 3 (`mdnsd daemon is running`) and `mdns-cleanup.t`
dies at its `mdnsd required` precondition. Both files then cannot run. The
provisioning hardening added this session (set flags to the default-route
interface, enable, restart, verify) did not change the outcome, and the
foreground-`mdnsd` diagnostics did not print — meaning either the provisioning
block did not reach them or `mdnsd` was alive at provisioning time but not at
test time. mDNS depends on link-local multicast, which QEMU user-mode (SLIRP)
networking does not carry.

## Tasks

### 3.1 Establish the actual failure

- Read the provisioning-phase diagnostics already emitted
  (`scripts/vm_provision.sh`): the chosen interface, `rcctl get mdnsd`, and the
  short foreground `mdnsd -d` output. Determine definitively whether `mdnsd`
  fails to start, starts then exits, or runs but `rcctl check` misreports it.
- In a local VM, start `mdnsd` by hand on the guest interface and observe
  whether it stays up and whether `mdnsctl browse` returns anything under
  user-mode networking.

### 3.2 Decide the resolution path

Pick based on 3.1, in preference order:

1. **Make mdnsd run as-is.** If it is a flags/interface/rc issue (not a
   transport limit), fix provisioning so `mdnsd` is reliably up before the
   tests, and the tests pass unchanged.
2. **Give the guest real multicast.** If user-mode networking is the blocker,
   switch the VM's network for CI to a mode that carries multicast (e.g. a
   tap/bridged backend) in `lib/OpenHVF/VM.pm` / `.openhvfrc`, gated so local
   development is unaffected. Document the requirement.

Do **not** add a `skip` to the mDNS tests — `t/openhap/integration/CLAUDE.md`
forbids it. If mDNS genuinely cannot run in the chosen CI network, that is a
harness capability to provide (option 2), not a test to soften.

### 3.3 Implement and verify

- Apply the chosen fix; confirm `mdnsd` is up and `mdnsctl browse` sees the
  `_hap._tcp` service `openhapd` registers.

## Deliverables

- Provisioning and/or `OpenHVF` networking change with a one-paragraph rationale
  in the commit body (which of 3.2's paths and why).
- Any doc updates (`INSTALL.md` / `man/openhvf/openhvf.1`) if the VM network
  configuration changes.

## Acceptance criteria

- `mdns.t` (12/12) and `mdns-cleanup.t` (6/6) pass in the Integration workflow.
- Local `make integration` on a developer host (HVF/KVM) still passes, i.e. the
  networking change does not regress the non-CI path.
- `make check` stays green.
