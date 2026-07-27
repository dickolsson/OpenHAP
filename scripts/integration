#!/bin/sh
# ex:ts=8 sw=4:
# Run integration tests in the OpenBSD VM

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OPENHVF="${PROJECT_ROOT}/bin/openhvf"

# Get SSH port from openhvf status
SSH_PORT=$(${OPENHVF} status 2>/dev/null | grep ssh_port | awk '{print $2}')
SSH_PORT="${SSH_PORT:-2222}"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

vm_run() { "${OPENHVF}" ssh "$@"; }
vm_scp() { scp ${SSH_OPTS} -P "${SSH_PORT}" "$@"; }

echo "==> Copying test files..."
cd "${PROJECT_ROOT}"
TARBALL="/tmp/tests-$$.tar.gz"
tar czf "${TARBALL}" t/openhap/integration/ t/lib/ lib/OpenHAP/Test/
vm_scp "${TARBALL}" "root@127.0.0.1:/tmp/tests.tar.gz"
rm -f "${TARBALL}"

echo "==> Running integration tests..."
# The heredoc runs under its own set -e so a broken guest setup step
# fails the run loudly instead of reporting a half-prepared suite; the
# host-side set -e is suspended so the failure diagnostics below stay
# reachable when vm_run fails.
set +e
vm_run <<'EOF'
set -e
cd /tmp && tar xzf tests.tar.gz

# Refresh the shipped test helper modules (Test::Controller and the
# shared mocks in t/lib) over the installed copies
cp -R lib/OpenHAP/Test /usr/local/libdata/perl5/site_perl/OpenHAP/

# Clean up any orphaned processes from previous test runs, gracefully:
# a SIGKILLed mdnsctl leaves mdnsd holding a dead client socket, which
# is a suspected cause of mdnsd exiting under client churn. TERM first,
# KILL only stragglers.
rcctl stop openhapd >/dev/null 2>&1 || true
pkill -f 'perl.*openhapd' 2>/dev/null || true
pkill mdnsctl 2>/dev/null || true
sleep 2
pkill -9 -f 'perl.*openhapd' 2>/dev/null || true
pkill -9 mdnsctl 2>/dev/null || true
sleep 1

# Start the daemon fresh
rcctl start openhapd >/dev/null 2>&1 || true
sleep 2

# Set integration test flag
export OPENHAP_INTEGRATION_TEST=1

# The test controller talks to the real daemon, whose SRP modexp is slow
# under TCG emulation. Give its socket reads a generous timeout so
# pair-setup/pair-verify do not give up before the daemon responds.
export OPENHAP_TEST_TIMEOUT="${OPENHAP_TEST_TIMEOUT:-60}"

# Run tests in order (environment first, then others)
TESTS="t/openhap/integration/environment.t"
for test in t/openhap/integration/*.t; do
	[ "$test" = "t/openhap/integration/environment.t" ] && continue
	TESTS="$TESTS $test"
done

result=0
if command -v prove >/dev/null 2>&1; then
	prove -I/usr/local/libdata/perl5/site_perl -It/lib -v $TESTS || result=$?
else
	for test in $TESTS; do
		[ -f "$test" ] || continue
		echo "Running $test..."
		perl -I/usr/local/libdata/perl5/site_perl -It/lib "$test" || result=1
	done
fi

rm -rf /tmp/t /tmp/lib /tmp/tests.tar.gz
exit $result
EOF
result=$?
set -e

if [ ${result} -ne 0 ]; then
	echo "==> Capturing failure diagnostics..."
	echo "-- daemon log --"
	vm_run 'cat /var/log/openhapd.log 2>/dev/null' || true
	vm_run 'tail -80 /var/log/daemon 2>/dev/null | grep -e openhap -e mdnsd' || true
	echo "-- pairing state (/var/db/openhapd) --"
	vm_run 'ls -l /var/db/openhapd 2>/dev/null;
		cat /var/db/openhapd/pairings.db 2>/dev/null' || true
	echo "-- service status --"
	vm_run 'rcctl check openhapd; rcctl check mdnsd; rcctl get mdnsd;
		ps -axo pid,command | grep -e mdnsd -e mdnsctl |
		grep -v grep' || true
fi

exit ${result}
