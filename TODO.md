# OpenHAP TODO List

This document tracks areas that need further implementation, improvements, or
refinements.

## High Priority

### Security & Hardening

- [x] **Implement full pledge(2) restrictions**
  - Implemented: `FuguLib::Sandbox` (real on OpenBSD, no-op elsewhere); openhapd
    pledges `stdio rpath wpath cpath fattr flock inet dns unix` after the
    privilege drop and mDNS publish, before any network input. No `proc`, `exec`
    or `prot_exec`: the mdnsctl child was replaced with a native mdnsd control
    client (`FuguLib::MDNS` over `FuguLib::Imsg`, spec/MDNS-\*.md)
  - Proven by: `t/fugulib/sandbox.t` (SIGABRT on violation, asserted from the
    parent) and `t/openhap/integration/sandbox.t` (ktrace shows the syscall with
    the exact promise string)
  - Files: `lib/FuguLib/Sandbox.pm`, `bin/openhapd`

- [x] **Implement full unveil(2) restrictions**
  - Implemented: ordered inventory with per-path required/optional dispositions,
    assembled by `OpenHAP::Daemon->unveil_paths`, applied and locked between the
    privilege drop and the pledge; optional paths (config file, daemon log,
    mdnsd socket, resolver files) never fail startup
  - Proven by: `t/openhap/daemon.t` (inventory), `t/fugulib/sandbox.t`
    (enforcement), `t/openhap/integration/sandbox.t` (trace and lock ordering)
  - Files: `lib/OpenHAP/Daemon.pm`, `bin/openhapd`

- [ ] **Pledge and unveil hapctl**
  - Current: only openhapd is restricted
  - Need: `hapctl` reads config and state and prints, so `stdio rpath` plus a
    handful of unveiled paths covers it; cheap now that `FuguLib::Sandbox`
    exists, and the asymmetry with a pledged openhapd goes unnoticed otherwise
  - File: `bin/hapctl`

- [ ] **Verify what grants \_openhap access to /var/run/mdnsd.sock**
  - Current: the socket is root:wheel 0660 and provisioning adds `_openhap` to
    wheel, but `FuguLib::Privdrop` calls only `setgid`/`setuid` and Perl's
    `$) = $gid` assignment itself invokes `setgroups`, which would drop
    supplementary groups rather than keep them - so the mechanism that makes the
    connect succeed today is unverified, and may be retained root supplementary
    groups (a mild privilege leak in its own right)
  - Need: measure `id` and group set of the running daemon in the VM, then make
    privdrop set supplementary groups deliberately
  - Files: `lib/FuguLib/Privdrop.pm`, `bin/openhapd`

- [ ] **Re-establish the mDNS advertisement after an mdnsd restart**
  - Current: the advertisement lives exactly as long as the held control socket;
    if mdnsd restarts, discovery is gone until openhapd restarts. Parity with
    the old mdnsctl behaviour - a known limitation, now recorded
  - Need: detect the closed socket in the event loop and republish
  - File: `lib/OpenHAP/HAP.pm`, `bin/openhapd`

- [ ] **Implement mdnsd browse, resolve and lookup**
  - Current: `spec/MDNS-Control.md` §11 specifies all three message shapes, but
    only publish is implemented; `make spec-coverage` shows the uncovered
    sections, which is deliberate rather than an oversight
  - Need: implement in `FuguLib::MDNS` when a consumer appears
  - File: `lib/FuguLib/MDNS.pm`

- [ ] **Fix rcctl reload: SIGHUP stops the daemon instead of reloading**
  - Current: `etc/rc.d/openhapd` reloads with `pkill -HUP`, but openhapd
    registers HUP as a graceful _exit_, so `rcctl reload openhapd` stops the
    daemon - and since the held control socket is the mDNS advertisement, also
    withdraws it
  - Need: a real reload handler; note it must not re-exec, or `exec` returns to
    the promise set and the pledge benefit goes
  - Files: `bin/openhapd`, `etc/rc.d/openhapd`

- [ ] **Rate limiting for pairing attempts**
  - Current: No rate limiting in Pairing.pm
  - Need: Implement backoff/lockout after failed attempts
  - Spec: Max 100 attempts per 15 minutes per IP
  - File: `lib/OpenHAP/Pairing.pm`

- [ ] **Secure PIN generation**
  - Current: Default PIN '1995-1018' in code (configurable via config file)
  - Need: Generate cryptographically random PIN on first run if not configured
  - Should: Display PIN on console, save to secure file
  - File: `lib/OpenHAP/Storage.pm`, `bin/openhapd`
  - Note: PIN validation implemented in `lib/OpenHAP/PIN.pm`

- [ ] **Input validation**
  - Current: Limited validation on HTTP requests
  - Need: Validate all TLV inputs, characteristic values, JSON payloads
  - File: `lib/OpenHAP/HTTP.pm`, `lib/OpenHAP/Pairing.pm`, `lib/OpenHAP/HAP.pm`

### Core Functionality

- [ ] **HAP EVENT notifications**
  - Current: Event callbacks exist but no EVENT streaming
  - Need: Implement Server-Sent Events over HTTP/1.1
  - Protocol: Long-lived connection with chunked transfer encoding
  - File: `lib/OpenHAP/HAP.pm`

- [x] **MQTT subscription with callbacks**
  - Implemented: Event loop integration via tick() method
  - Features: Topic wildcards (+/#), callback dispatch, reconnection support
  - Integration: HAP server polls MQTT in select loop with 100ms timeout
  - Reconnection: Automatic reconnection every 30 seconds with resubscription
  - Files: `lib/OpenHAP/MQTT.pm`, `lib/OpenHAP/HAP.pm`

- [x] **Proper daemon mode**
  - Implemented: Fork to background, setsid, redirect I/O to
    /var/log/openhapd.log
  - Features: Daemonizes unless -f flag is used, proper process separation
  - Includes: Connection timeout for MQTT to prevent blocking on startup
  - Includes: Automatic MQTT reconnection every 30 seconds if connection lost
  - File: `bin/openhapd`, `lib/OpenHAP/Daemon.pm`, `lib/OpenHAP/MQTT.pm`,
    `lib/OpenHAP/HAP.pm`

- [x] **Signal handling**
  - Implemented: `FuguLib::Signal` handlers for graceful shutdown on SIGTERM,
    SIGINT and SIGHUP, with cleanup callbacks (mDNS withdrawal, logger close)
  - Note: SIGHUP currently _exits_ rather than reloads - see the rcctl reload
    item under Security & Hardening
  - File: `bin/openhapd`, `lib/FuguLib/Signal.pm`

- [ ] **Logging with syslog**
  - Current: Partial syslog implementation exists in `lib/OpenHAP/Log.pm`
  - Status: Log module with syslog integration completed
  - Need: Verify all modules use Log.pm consistently
  - Levels: debug, info, notice, warning, error, critical (implemented)
  - File: `lib/OpenHAP/Log.pm` (implemented), verify usage in all other modules

### Protocol Compliance

- [ ] **Pair-Remove implementation**
  - Current: Storage has remove_pairing but no endpoint
  - Need: Add `/pairings` POST endpoint for removing pairings
  - File: `lib/OpenHAP/HAP.pm`, `lib/OpenHAP/Pairing.pm`

- [ ] **Pair-Add implementation**
  - Current: No support for adding additional controllers
  - Need: Add `/pairings` POST endpoint for adding pairings
  - Requires: Admin controller permissions check
  - File: `lib/OpenHAP/HAP.pm`, `lib/OpenHAP/Pairing.pm`

- [ ] **Pair-List implementation**
  - Current: No endpoint to list pairings
  - Need: Add `/pairings` GET endpoint
  - File: `lib/OpenHAP/HAP.pm`

- [ ] **Proper HTTP/1.1 persistent connections**
  - Current: Connection closes after each request
  - Need: Support Connection: keep-alive header
  - File: `lib/OpenHAP/HAP.pm`, `lib/OpenHAP/HTTP.pm`

- [ ] **Content-Type validation**
  - Current: Accepts any content type
  - Need: Validate Content-Type headers (application/hap+json,
    application/pairing+tlv8)
  - File: `lib/OpenHAP/HTTP.pm`, `lib/OpenHAP/HAP.pm`

- [ ] **Multi-status responses for characteristics**
  - Current: Simple 204 for all PUT requests
  - Need: Return 207 Multi-Status with individual status codes
  - File: `lib/OpenHAP/HAP.pm`

## Medium Priority

### Device Support

- [x] **Tasmota device types implemented**
  - [x] Temperature/humidity sensors (`lib/OpenHAP/Tasmota/Sensor.pm`)
  - [x] Heater/switch devices (`lib/OpenHAP/Tasmota/Heater.pm`)
  - [x] Thermostat devices (`lib/OpenHAP/Tasmota/Thermostat.pm`)

- [ ] **Additional Tasmota device types**
  - [ ] Light bulbs with brightness control
  - [ ] RGB/RGBW lights with color control
  - [ ] Fans with speed control
  - [ ] Garage door opener
  - [ ] Motion sensors
  - [ ] Door/window contact sensors
  - Files: New files in `lib/OpenHAP/Tasmota/`

- [ ] **Generic MQTT device support**
  - Current: Only Tasmota-specific protocol
  - Need: Configurable topic/payload patterns
  - File: New `lib/OpenHAP/MQTT/Device.pm`

- [ ] **Device discovery**
  - Current: Manual configuration only
  - Need: Auto-discover Tasmota devices via MQTT
  - Method: Subscribe to `tasmota/discovery/#`
  - File: `lib/OpenHAP/MQTT.pm`, `bin/openhapd`

### Configuration

- [ ] **Configuration reload**
  - Current: Requires daemon restart
  - Need: Reload config on SIGHUP without losing pairings
  - File: `bin/openhapd`, `lib/OpenHAP/Config.pm`

- [ ] **Configuration validation**
  - Current: Minimal validation
  - Need: Validate device blocks, required fields, data types
  - File: `lib/OpenHAP/Config.pm`

- [ ] **Environment variable support**
  - Current: No environment variable substitution
  - Need: Support ${VAR} syntax in config file
  - File: `lib/OpenHAP/Config.pm`

### Testing

- [x] **Unit tests for core modules**
  - [x] `OpenHAP::TLV` - TLV8 encoding/decoding
  - [x] `OpenHAP::HTTP` - HTTP request parsing
  - [x] `OpenHAP::Config` - Configuration file parsing
  - [x] `OpenHAP::Crypto` - Encryption and key generation
  - [x] `OpenHAP::SRP` - SRP protocol
  - [x] `OpenHAP::Pairing` - Pairing flows
  - [x] `OpenHAP::Session` - Session encryption
  - [x] `OpenHAP::Storage` - Persistence layer
  - [x] `OpenHAP::Accessory` - Accessory management
  - [x] `OpenHAP::Bridge` - Bridge functionality
  - [x] `OpenHAP::Characteristic` - Characteristic handling
  - [x] `OpenHAP::Service` - Service management
  - [x] `OpenHAP::MQTT` - MQTT client
  - [x] `OpenHAP::Daemon` - Daemon utilities
  - [x] `OpenHAP::Log` - Logging system
  - [x] `OpenHAP::PIN` - PIN validation
  - [x] `OpenHAP::DeviceLoader` - Device configuration loading
  - Total: 17 test files in `t/openhap/`

- [ ] **Integration test infrastructure**
  - Status: Framework exists but needs QEMU VM setup to be functional
  - Current: Test files exist in `t/openhap/integration/`
    - [x] `00-mock-test.t` - Mock test framework
    - [x] `01-daemon-status.t` - Daemon health checks
    - [x] `02-api-endpoints.t` - API validation
    - [x] `03-config-loading.t` - Configuration tests
    - [x] `04-workflow.t` - End-to-end workflow
    - [x] `05-logging.t` - Logging tests
  - Scripts exist:
    `scripts/integration/{provision.sh,run-tests.sh,integration-test.sh}`
  - Need: Complete QEMU VM setup as documented in detailed section below
  - Note: Can run tests manually but not yet automated in CI/CD

- [ ] **QEMU-based integration tests**
  - Status: Framework infrastructure exists, needs VM image and automation work
  - Current: Test infrastructure in place with scripts and test files
  - Framework Components (✓ Complete):
    - [x] Integration test files in `t/openhap/integration/*.t` (6 tests)
    - [x] Shell scripts in `scripts/integration/` for VM management
    - [x] Documentation in `scripts/integration/README.md`

  - **What's needed to make integration tests work:**
    1. **Pre-built OpenBSD VM Image** (HIGH PRIORITY)
       - Current issue: OpenBSD installation requires interactive setup
       - Solution options: a. Create pre-installed OpenBSD QCOW2 image with
         OpenHAP
         - Boot official OpenBSD image
         - Complete unattended installation (using autoinstall(8))
         - Install OpenHAP and dependencies
         - Package as reusable QCOW2 image
         - Host on GitHub releases or CDN b. Use OpenBSD autoinstall feature
         - Create install.conf for unattended installation
         - Boot with -kernel/-initrd for automated setup
         - Provision OpenHAP post-install
       - Estimated time: 4-8 hours to create and test
       - Files needed:
         - `scripts/integration/build-openbsd-image.sh` - Build automation
         - `share/openhap/examples/install.conf` - Autoinstall configuration
         - GitHub release with pre-built image

    2. **Passwordless SSH Access** (HIGH PRIORITY)
       - Current issue: provision-vm.sh and run-integration-tests.sh need SSH
       - Solution options: a. Embed SSH public key in pre-built image
         - Add key to /root/.ssh/authorized_keys during image build
         - Generate ephemeral key pair in CI b. Use QEMU serial console instead
           of SSH
         - Send commands via QEMU monitor
         - More complex but avoids SSH dependency
       - Estimated time: 2-4 hours
       - Files to modify:
         - `scripts/integration/provision-vm.sh`
         - `scripts/integration/run-integration-tests.sh`
         - Add `scripts/integration/generate-ssh-key.sh`

    3. **GitHub Actions Runner Optimization** (MEDIUM PRIORITY)
       - Current issue: QEMU without KVM is slow
       - Solutions: a. Use ubuntu-latest (has KVM support via nested
         virtualization) b. Reduce VM memory/CPU requirements for CI c.
         Implement timeout protection (currently 30 min default) d. Cache
         pre-warmed VM disk snapshots
       - GitHub Actions specific settings:
         - Enable hardware acceleration if available
         - Use matrix strategy to parallelize tests
         - Add reasonable timeouts (job: 60min, VM boot: 10min)
       - Estimated time: 1-2 hours
       - Files to modify:
         - `.github/workflows/integration.yml` - Add KVM setup, caching
         - `scripts/integration/setup-vm.sh` - Optimize for CI environment

    4. **Automated Test Execution** (MEDIUM PRIORITY)
       - Current issue: Tests require running VM and services
       - Needed: a. Health check before running tests
         - Wait for SSH to be available
         - Wait for openhapd to start
         - Wait for port 51827 to listen
         - Implement retry logic with backoff b. Service startup validation
         - Verify mosquitto is running
         - Verify openhapd process exists
         - Check logs for startup errors c. Test result collection
         - Capture test output
         - Collect logs on failure
         - Generate test reports
       - Estimated time: 3-4 hours
       - Files to modify:
         - `scripts/integration/provision-vm.sh` - Add health checks
         - `scripts/integration/run-integration-tests.sh` - Better error
           handling
         - Add `scripts/integration/wait-for-service.sh` - Health check helper

    5. **Network Configuration** (LOW PRIORITY)
       - Current implementation: QEMU user networking (SLIRP)
       - Status: Currently working, but could be improved
       - Possible improvements: a. Use TAP networking for better performance b.
         Configure specific port ranges to avoid conflicts c. Add network
         isolation for security
       - Estimated time: 2-3 hours if needed
       - Files to modify:
         - `scripts/integration/setup-vm.sh` - Add TAP networking option

    6. **Test Environment Variables** (LOW PRIORITY)
       - Current: Many hardcoded defaults
       - Improvements needed:
         - Make all timeouts configurable
         - Allow custom OpenBSD mirror
         - Support air-gapped/offline testing
         - Add verbose/debug modes
       - Estimated time: 1-2 hours
       - Files to modify:
         - All `scripts/integration/*.sh` - Better env var support

  - **Implementation Steps for GitHub Actions:**

    **Phase 1: Create Pre-built Image (Required for CI)**

    ```bash
    # 1. Create automated OpenBSD installation script
    scripts/integration/build-openbsd-image.sh

    # 2. Build image locally
    make integration-build-image

    # 3. Test image boots and runs OpenHAP
    make integration-test-image

    # 4. Upload to GitHub releases
    gh release create v1.0-openbsd-image openbsd-75-openhap.qcow2.gz

    # 5. Update download-openbsd-image.sh to fetch pre-built image
    ```

    **Phase 2: Enable SSH Access**

    ```bash
    # 1. Generate SSH key pair in CI
    - name: Generate SSH key
      run: |
        ssh-keygen -t ed25519 -f ~/.ssh/openhap_test -N ""
        echo "SSH_PRIVATE_KEY=$(cat ~/.ssh/openhap_test)" >> $GITHUB_ENV

    # 2. Pre-built image includes corresponding public key
    # 3. Update provision-vm.sh to use key-based auth
    ```

    **Phase 3: Update GitHub Actions Workflow**

    ```yaml
    # Note: .github/workflows/integration.yml does not yet exist
    # Will need to create when pre-built image is ready
    # Add to workflow:
    - name: Enable KVM
      run: |
        # Check if KVM is available
        if [ -e /dev/kvm ]; then
          echo "KVM is available"
          sudo chmod 666 /dev/kvm
        else
          echo "KVM not available, using TCG emulation"
        fi

    - name: Cache OpenBSD VM image
      uses: actions/cache@v3
      with:
        path: ~/.cache/openhap-integration
        key: openbsd-vm-${{ matrix.openbsd_version }}-v1

    - name: Run integration tests
      timeout-minutes: 30
      run: make integration
    ```

    **Phase 4: Testing and Validation**

    ```bash
    # 1. Test locally first
    make integration

    # 2. Test in act (local GitHub Actions runner)
    act -j integration-test

    # 3. Create PR and verify in GitHub Actions
    # 4. Monitor timing and adjust timeouts
    # 5. Verify test results and logs
    ```

  - **Alternative: Minimal Integration Tests Without Full VM**

    If building a full VM proves too complex, consider:
    1. **Mock Integration Tests** (Quick win)
       - Run OpenHAP in foreground on GitHub Actions runner
       - Use local mosquitto
       - Test basic API without actual pairing
       - Estimated time: 2-3 hours

    2. **Container-based Testing** (Alternative approach)
       - Use OpenBSD container (if available)
       - Or use Linux with OpenHAP
       - Less authentic but easier to automate
       - Estimated time: 3-4 hours

  - **Success Criteria:**
    - [ ] Integration tests run automatically in GitHub Actions
    - [ ] Tests complete in < 15 minutes (with cached image)
    - [ ] Tests have < 5% flake rate
    - [ ] Clear failure messages and log collection
    - [ ] Tests run on schedule (weekly) and on relevant PRs
    - [ ] All 4 integration test files pass
    - [ ] VM properly shuts down and cleans up

- [ ] **Integration tests**
  - [ ] Full pairing flow test (M1-M6)
  - [ ] Pair-verify flow test (M1-M4)
  - [ ] Encrypted session test
  - [ ] Accessory discovery test
  - [ ] Characteristic read/write test
  - [ ] MQTT device control test
  - Files: New `t/openhap/integration/` directory

- [ ] **End-to-end tests**
  - [ ] Test with real iOS Home app
  - [ ] Test with Tasmota devices
  - [ ] Test with mosquitto broker
  - [ ] Test pairing persistence across restarts
  - [ ] Test multiple controllers
  - [ ] Test event notifications
  - Files: New `t/e2e/` directory

- [ ] **Performance tests**
  - [ ] Test with multiple devices (10, 50, 100)
  - [ ] Test concurrent client connections
  - [ ] Test memory usage over time
  - [ ] Test pairing flow latency
  - Files: New `t/performance/` directory

- [ ] **Security tests**
  - [ ] Test pairing PIN brute force protection
  - [ ] Test encryption with invalid keys
  - [ ] Test replay attack protection
  - [ ] Test malformed TLV handling
  - Files: New `t/security/` directory

### Documentation

- [x] **Man pages**
  - [x] openhapd(8) - Daemon man page
  - [x] openhapd.conf(5) - Configuration file man page
  - [x] hapctl(8) - Control utility man page
  - Files: `man/openhap/` directory

- [ ] **Protocol documentation**
  - Current: Comments in code
  - Need: Detailed protocol flow documentation
  - File: New `docs/PROTOCOL.md`

- [ ] **Examples and tutorials**
  - [ ] Basic setup tutorial
  - [ ] Adding custom device types
  - [ ] Troubleshooting guide
  - [ ] Performance tuning guide
  - Files: New `docs/tutorials/` directory

## Low Priority

### Features

- [ ] **QR code generation for pairing**
  - Current: Manual PIN entry only
  - Need: Generate QR code containing setup payload
  - Module: Text::QRCode or similar
  - File: `bin/openhapd`

- [ ] **Web-based configuration UI**
  - Current: Manual config file editing
  - Need: Simple web interface for configuration
  - Framework: Mojolicious::Lite or Dancer2
  - Files: New `lib/OpenHAP/Web/` directory

- [ ] **Device grouping/scenes**
  - Current: No scene support
  - Need: Create scenes that control multiple devices
  - File: New `lib/OpenHAP/Scene.pm`

- [ ] **Automation rules**
  - Current: No automation
  - Need: Simple if-then rules (temp > 20 -> turn off heater)
  - File: New `lib/OpenHAP/Automation.pm`

- [ ] **Status monitoring endpoint**
  - Current: No status API
  - Need: HTTP endpoint for daemon status, device status
  - Endpoint: `/status` or Unix socket
  - File: `lib/OpenHAP/HAP.pm`

- [ ] **Metrics/statistics**
  - Current: No metrics collected
  - Need: Track pairing attempts, requests, errors, latency
  - Export: Prometheus format or JSON
  - File: New `lib/OpenHAP/Metrics.pm`

### OpenBSD Integration

- [ ] **rc.d script improvements**
  - Current: Basic rc.d script
  - Need: Better error messages, status checking
  - File: `etc/rc.d/openhapd`

- [ ] **Login class for resource limits**
  - Current: No resource limits
  - Need: Define login class in login.conf
  - File: New example in `share/openhap/examples/`

- [ ] **Privilege separation**
  - Current: Single process, now pledged and unveiled, which changes what
    separation would buy: the monolith already cannot exec, fork, or see the
    filesystem outside its inventory, so the remaining win is isolating key
    material from the network-facing parser rather than syscall reduction
  - Need: Separate processes for privileged operations; note that helper
    processes would put `proc` (and likely `sendfd`/`recvfd`) back into the
    parent's promise set
  - File: `bin/openhapd`, new helper processes

### Packaging

- [ ] **OpenBSD port**
  - [ ] Create Makefile for ports
  - [ ] Create pkg/DESCR
  - [ ] Create pkg/PLIST
  - [ ] Create pkg/MESSAGE
  - [ ] Test on current, stable, -release
  - Files: New `ports/net/openhap/` directory

- [ ] **Dependency management**
  - Current: Dependencies listed in `cpanfile`
  - Need: Bundle dependencies or clear installation script
  - File: `cpanfile` exists, consider adding `scripts/install-deps.sh`

- [x] **Automated builds**
  - Implemented: GitHub Actions for testing
  - File: `.github/workflows/test.yml`, `.github/workflows/release.yml`
  - Tests run on: Perl 5.32, 5.34, 5.36, 5.38

- [ ] **Release process**
  - Current: No formal release process
  - Need: Version tagging, changelog, release notes
  - Files: New `CHANGELOG.md`, version tagging

## Technical Debt

### Known Shortcuts/Limitations

- [ ] **SRP implementation completeness**
  - Location: `lib/OpenHAP/SRP.pm`
  - Issue: Uses Math::BigInt which is slower than C implementation
  - Need: Consider Crypt::SRP for better performance
  - Impact: Pairing takes longer than necessary

- [ ] **HTTP parser robustness**
  - Location: `lib/OpenHAP/HTTP.pm`
  - Issue: Simple regex-based parsing, not fully RFC compliant
  - Need: Handle edge cases, malformed requests
  - Impact: May fail on unusual requests

- [ ] **Session management**
  - Location: `lib/OpenHAP/HAP.pm:86-99`
  - Issue: No session timeout, unlimited sessions in memory
  - Need: Session timeout and cleanup
  - Impact: Memory leak potential

- [ ] **Encryption error handling**
  - Location: `lib/OpenHAP/Session.pm:48-96`
  - Issue: Decryption failure returns undef, no context
  - Need: Better error reporting
  - Impact: Hard to debug encryption issues

- [ ] **Storage file locking**
  - Location: `lib/OpenHAP/Storage.pm:48-76`
  - Issue: flock used but no timeout handling
  - Need: Timeout and lock failure handling
  - Impact: Potential deadlock

- [ ] **Config parser error handling**
  - Location: `lib/OpenHAP/Config.pm:21-62`
  - Issue: Parse errors silently skipped
  - Need: Validation and error reporting
  - Impact: Invalid config may be partially loaded

- [ ] **Device initialization error handling**
  - Location: `bin/openhapd:67-86`
  - Issue: Device initialization errors not caught
  - Need: Try/catch around device creation
  - Impact: One bad device breaks entire server

## Corner Cases to Handle

- [ ] **Pairing with multiple controllers simultaneously**
  - Current: No protection against concurrent pairing
  - Need: Lock pairing during active pairing flow

- [ ] **Characteristic updates during pairing**
  - Current: May allow characteristic access before pair-verify
  - Need: Strict verification check on all endpoints

- [ ] **Large TLV values (>255 bytes)**
  - Current: Chunking implemented but not tested
  - Need: Test with large certificates/keys

- [ ] **Network interruption during pairing**
  - Current: Session state may be lost
  - Need: Timeout and cleanup of incomplete pairings

- [ ] **MQTT broker disconnection**
  - Current: Automatic reconnection implemented every 30 seconds
  - Status: Basic reconnection works, resubscribes to all topics
  - Enhancement: Could add exponential backoff for failed reconnects
  - File: `lib/OpenHAP/MQTT.pm`, `lib/OpenHAP/HAP.pm`

- [ ] **File system full conditions**
  - Current: No space checking before writing
  - Need: Check available space, handle ENOSPC

- [ ] **Permission denied errors**
  - Current: Dies on permission errors
  - Need: Graceful error messages, suggest fixes

## hapctl Administrative Tool

The `hapctl` utility provides administrative control for OpenHAP. Current
implementation is minimal with basic commands. Future enhancements planned:

### Implemented Commands

- [x] **check** - Validate configuration file syntax
- [x] **status** - Show daemon status and pairing information
- [x] **devices** - List configured devices from config file

### Planned Commands

- [ ] **pair** - Display pairing code and QR code for setup
  - Generate QR code from setup URI
  - Show PIN prominently for manual entry
  - Optional: Copy setup URI to clipboard

- [ ] **unpair** - Reset all pairings and regenerate credentials
  - Remove all controller pairings
  - Regenerate device keys
  - Require confirmation flag (--force)

- [ ] **accessories** - List runtime accessory information
  - Show current characteristic values
  - Display connection status
  - MQTT subscription state

- [ ] **controllers** - Manage paired iOS/HomeKit controllers
  - List paired controllers with identifiers
  - Remove specific controller pairing
  - Show last connection time

- [ ] **mqtt** - MQTT diagnostics and testing
  - Test MQTT broker connection
  - Subscribe to topics and display messages
  - Publish test messages

### Technical Improvements

- [ ] **JSON output mode** - Add --json flag for machine-readable output
- [ ] **Unix socket communication** - Direct daemon queries via socket
- [ ] **Tab completion** - Shell completion scripts for bash/zsh
- [ ] **Color output** - Colorize status indicators and errors
- [ ] **Verbose mode** - Add -v flag for detailed diagnostic output

### Integration

- [ ] **rc.d script integration** - Use hapctl in rc script for status checks
- [ ] **Monitoring hooks** - Export metrics for Prometheus/Nagios
- [ ] **Syslog correlation** - Cross-reference log entries by timestamp

Files: `bin/hapctl`, `lib/OpenHAP/Daemon.pm`, `lib/OpenHAP/Storage.pm`

## Future Enhancements

- [ ] **Bluetooth LE HAP support**
  - Status: Out of scope for initial release
  - Benefit: Support devices without network

- [ ] **HomeKit Secure Video**
  - Status: Out of scope for initial release
  - Benefit: Security camera integration

- [ ] **Thread/Matter support**
  - Status: Out of scope for initial release
  - Benefit: Low-power mesh networking

- [ ] **Cloud relay (for remote access)**
  - Status: Out of scope for initial release
  - Benefit: Access from outside local network

- [ ] **Bridge multiple MQTT brokers**
  - Status: Enhancement
  - Benefit: Integrate devices from different networks

- [ ] **Plugin system**
  - Status: Enhancement
  - Benefit: Third-party device support

---

## Priority Legend

- **High Priority**: Security issues, broken functionality, blocking bugs
- **Medium Priority**: Missing features, quality improvements, better UX
- **Low Priority**: Nice-to-haves, optimizations, polish

## Contributing

When working on items from this TODO list:

1. Check if item is still relevant (may have been completed)
2. Create issue on GitHub for discussion
3. Create feature branch from main
4. Implement with tests
5. Update this TODO.md (mark as done or remove)
6. Submit pull request

## Notes

- Items marked with specific file locations should be addressed in those files
- Some items require new files/directories to be created
- Test coverage should increase with each implementation
- Maintain backward compatibility where possible
- Document all new features in README.md and relevant docs
