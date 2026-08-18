# OpenHAP TODO List

This document tracks the open work that adds HAP capabilities, adds security
capabilities, or improves the coherency of the implementation.

## Security

- [ ] **Pledge and unveil hapctl**
  - Current: only openhapd is restricted
  - Need: `hapctl` reads config and state and prints, so `stdio rpath` plus a
    handful of unveiled paths covers it; cheap now that `Fugu::Sandbox` exists,
    and the asymmetry with a pledged openhapd goes unnoticed otherwise
  - File: `bin/hapctl`

- [ ] **Verify what grants \_openhap access to /var/run/mdnsd.sock**
  - Current: the socket is root:wheel 0660 and provisioning adds `_openhap` to
    wheel, but `Fugu::Privdrop` calls only `setgid`/`setuid` and Perl's
    `$) = $gid` assignment itself invokes `setgroups`, which would drop
    supplementary groups rather than keep them - so the mechanism that makes the
    connect succeed today is unverified, and may be retained root supplementary
    groups (a mild privilege leak in its own right)
  - Need: measure `id` and group set of the running daemon in the VM, then make
    privdrop set supplementary groups deliberately
  - Files: `Fugu::Privdrop` (FuguBSD/Fugu), `bin/openhapd`

- [ ] **Secure setup-code generation**
  - Current: default setup code '1995-1018' in code (configurable via config
    file)
  - Need: generate a cryptographically random setup code on first run if not
    configured
  - Should: display the setup code on the console, save it to a secure file
  - Files: `lib/Protocol/HAP/Store/File.pm`, `bin/openhapd`
  - Note: setup-code validation implemented in `lib/Protocol/HAP/SetupCode.pm`

- [ ] **Throttle failed pair-setup attempts**
  - Current: a persistent counter locks pair-setup after 100 failed attempts
    (kTLVError_MaxTries, HAP-Pairing.md §8); the spec-required behavior is
    complete, but a controller can burn all 100 attempts in seconds
  - Need: a backoff delay between failed attempts, so a brute force cannot
    exhaust the counter quickly
  - File: `lib/Protocol/HAP/Pairing.pm`

- [ ] **Input validation**
  - Current: limited validation on HTTP requests
  - Need: validate all TLV inputs, characteristic values, JSON payloads
  - Files: `lib/Protocol/HAP/HTTP.pm`, `lib/Protocol/HAP/Pairing.pm`,
    `lib/Protocol/HAP/Server.pm`

- [ ] **Bound the connection map**
  - Current: no idle timeout and no connection limit; an unpaired client can
    open connections until memory runs out
  - Need: an idle timeout and a cap on concurrent connections
  - File: `lib/App/OpenHAP/Host.pm`

- [ ] **Privilege separation**
  - Current: single process, now pledged and unveiled, which changes what
    separation would buy: the monolith already cannot exec, fork, or see the
    filesystem outside its inventory, so the remaining win is isolating key
    material from the network-facing parser rather than syscall reduction
  - Need: separate processes for privileged operations; note that helper
    processes would put `proc` (and likely `sendfd`/`recvfd`) back into the
    parent's promise set
  - Files: `bin/openhapd`, new helper processes

## Coherency

- [ ] **Re-establish the mDNS advertisement after an mdnsd restart**
  - Current: the advertisement lives exactly as long as the held control socket;
    if mdnsd restarts, discovery is gone until openhapd restarts. Parity with
    the old mdnsctl behaviour - a known limitation, now recorded
  - Need: detect the closed socket in the event loop and republish
  - Files: `lib/App/OpenHAP/Host.pm`, `bin/openhapd`

- [ ] **Content-Type validation**
  - Current: accepts any content type on requests
  - Need: validate Content-Type headers (application/hap+json,
    application/pairing+tlv8)
  - Files: `lib/Protocol/HAP/HTTP.pm`, `lib/Protocol/HAP/Server.pm`

## Device support

- [ ] **Additional Tasmota device types**
  - [ ] Fans with speed control
  - [ ] Garage door opener
  - [ ] Motion sensors
  - [ ] Door/window contact sensors
  - Files: new files in `lib/App/OpenHAP/Tasmota/`
  - Note: sensors, heaters, thermostats, and lightbulbs (with brightness and
    color) exist

- [ ] **Generic MQTT device support**
  - Current: only Tasmota-specific protocol
  - Need: configurable topic/payload patterns
  - File: new `lib/App/OpenHAP/MQTT/Device.pm`

## CPAN release

Plan 008 decided every module name in the tree, so no naming question is left
here. The repository split moved `Fugu`, `Protocol-Imsg`, `App-FuguVM`, and
`App-FuguWeb` to their own repositories; each already builds a standard Perl
distribution tarball with `make dist`, and their remaining CPAN work lives with
them. What a release of this repository's distributions still needs is below. It
applies to `Protocol-HAP` and `App-OpenHAP`.

- [ ] A distribution main module for `App-OpenHAP`. PAUSE grants indexing
      permission on that module first, and none exists.
- [ ] A `$VERSION` policy. No module carries one, and PAUSE does not index a
      module without a version.
- [ ] PAUSE registration of each distribution name.
- [ ] `no_index` metadata for the packages that live inside another file:
      `Protocol::HAP::Log::Null` and `Protocol::HAP::SRP::Client`.
- [ ] Distribution tooling: `Makefile.PL` or `Build.PL`, `MANIFEST`, and
      distribution tests.
- [ ] A redistribution-license review of `spec/` before any spec text ships in a
      distribution.
