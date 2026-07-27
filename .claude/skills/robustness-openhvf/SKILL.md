---
name: robustness-openhvf
description:
  Adversarial robustness testing of the openhvf OpenBSD VM utility across 12
  areas (CLI parsing, config, filesystem, VM lifecycle, signals, concurrency,
  and more), writing findings to a scratchpad file. Use when asked to
  stress-test, fuzz, or try to break openhvf.
---

# Robustness Testing for openhvf

## Objective

Exercise the `openhvf` utility to find weaknesses in error handling, edge cases,
and failure modes. It is a general-purpose tool, so treat every input as coming
from someone who is not this repository. Be creative and adversarial—try to
break things in unexpected ways. For the command, option, and exit-code
reference, see `openhvf(1)` (`man/openhvf/openhvf.1`).

## Philosophy

OpenBSD's approach to robustness:

- **Fail closed**: Reject invalid input rather than guessing intent
- **Correctness first**: Better to refuse an operation than produce wrong
  results
- **Clear diagnostics**: Every failure must explain what went wrong and why
- **Clean failure**: Never leave partial state, orphaned processes, or corrupted
  files
- **Idempotency**: Operations that claim to be safe to repeat must truly be so

Your goal is not to follow a script, but to think like an attacker or a careless
user. What would happen if someone made a typo? What if the system is in an
unexpected state? What if two things happen at once?

## Test Areas

### 1. Command-Line Interface

**Goal**: Verify the CLI parser handles all forms of bad input gracefully.

Think about: unknown commands, misspelled options, missing arguments, empty
strings, extremely long arguments, special characters, unicode, null bytes,
arguments that look like options, options after positional arguments.

Every invalid invocation should produce a clear error and non-zero exit code.

### 2. Configuration Handling

**Goal**: Ensure the tool behaves predictably when configuration is missing,
malformed, or inconsistent.

Think about: running outside a project, corrupt config files, partial configs,
conflicting values, missing referenced VMs, circular references, configs with
unexpected types (arrays where scalars expected), extremely large config files.

The tool should never crash with a Perl stack trace—always a human-readable
error.

### 3. Filesystem Adversity

**Goal**: Test resilience to filesystem problems.

Think about: permission denied, read-only filesystems, missing directories,
symlink loops, paths with spaces and special characters, very long paths, disk
full conditions, files where directories expected (and vice versa), race
conditions with external file modifications.

Failed filesystem operations should not leave partial state behind.

### 4. VM Lifecycle State Machine

**Goal**: Verify state transitions are robust and idempotent where claimed.

Think about: stopping a stopped VM, starting a running VM, destroying while
starting, rapid start/stop cycles, operations when state file is corrupt or
missing, operations when QEMU process died unexpectedly, stale PID files, state
file pointing to wrong process.

The tool should always be able to recover to a known state.

### 5. Network and Port Resources

**Goal**: Ensure network resource conflicts are detected and reported clearly.

Think about: ports already in use, invalid port numbers, privileged ports, port
exhaustion, network interfaces disappearing, firewall blocking connections.

Conflicts should be detected early with clear error messages.

### 6. Signal and Interrupt Handling

**Goal**: Verify graceful handling of signals during all operations.

Think about: SIGINT during downloads, SIGTERM during VM startup, SIGHUP during
SSH sessions, signals arriving at critical moments (file writes, process
spawning), rapid repeated signals.

Interrupted operations must clean up completely—no orphaned processes, no
partial files, no corrupt state.

### 7. Timeouts and Hangs

**Goal**: Ensure the tool never hangs indefinitely and respects timeout values.

Think about: zero timeouts, negative timeouts, very large timeouts, waiting for
VMs that will never be ready, SSH to wrong ports, expect scripts that never
match, network connections that hang.

All waits should be bounded and interruptible.

### 8. Concurrency and Races

**Goal**: Find race conditions when multiple operations occur simultaneously.

Think about: parallel `up` commands, `status` while `start` is running, `stop`
racing with `start`, multiple terminal sessions operating on the same VM,
external QEMU manipulation during operations.

Concurrent operations should either serialize safely or fail with clear
errors—never corrupt state.

### 9. Resource Limits

**Goal**: Test behavior when resources are exhausted or limits exceeded.

Think about: very large disk sizes, excessive memory allocation, many
simultaneous VMs, file descriptor exhaustion, process limits, available disk
space.

Resource problems should produce clear errors, not crashes or hangs.

### 10. Expect Script Execution

**Goal**: Verify the expect subsystem handles script problems gracefully.

Think about: missing scripts, syntax errors in scripts, scripts that timeout,
scripts that produce no output, console connections that fail, expect patterns
that never match, scripts that run forever.

Script failures should clean up console connections and report what went wrong.

### 11. SSH Subsystem

**Goal**: Test SSH for proper handling of edge cases.

Think about: non-TTY stdin for interactive sessions, very long commands, shell
metacharacters and quoting, binary data in output, SSH before VM is ready, SSH
with wrong credentials, connection timeouts.

SSH should handle all edge cases without corrupting data or hanging.

### 12. Initialization and Setup

**Goal**: Verify `init` is truly idempotent and handles partial states.

Think about: double init, init over existing partial state, init in read-only
locations, init in deeply nested non-existent paths, init with unusual
characters in paths.

Init should be safe to run repeatedly and should fail cleanly when it cannot
proceed.

## Output

Record findings per the scratchpad convention in the root CLAUDE.md (which also
mandates `explore/`, never `/tmp`, for temporary test scripts). For each issue
found, report:

1. **Reproduction**: Exact steps or commands that trigger the problem
2. **Expected**: What should have happened
3. **Actual**: What actually happened (include exit codes, error messages)
4. **Severity**: Crash, hang, data corruption, unclear error, minor annoyance
5. **State after**: Was state left consistent? Any orphaned resources?

## Success Criteria

After testing, verify:

- No orphaned processes (QEMU, expect, ssh)
- State directory is consistent and recoverable
- No partial or corrupt files (disk images, downloads, configs)
- All temporary files cleaned up
- Tool can recover from any failure state with appropriate commands
