#!/bin/sh
# ex:ts=8 sw=4:
# Provision OpenHAP in the OpenBSD VM

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

echo "==> Building package..."
cd "${PROJECT_ROOT}"
make build

# Find the built tarball
TARBALL=$(ls -t build/openhap-*.tar.gz | head -1)
if [ ! -f "${TARBALL}" ]; then
	echo "Error: No tarball found in build/"
	exit 1
fi
echo "Using tarball: ${TARBALL}"

echo "==> Installing cpanm..."
vm_run <<'EOF'
pkg_add -u 2>/dev/null || true

# Install cpanm if not already present
if ! command -v cpanm >/dev/null 2>&1; then
	echo "Installing cpanm..."
	cpan -T App::cpanminus
fi
EOF

echo "==> Copying to VM..."
vm_scp "${TARBALL}" "root@127.0.0.1:/tmp/openhap.tar.gz"

echo "==> Installing OpenHAP..."
vm_run <<'EOF'
cd /tmp && rm -rf openhap && tar xzf openhap.tar.gz

# Uninstall existing version if present
if [ -f /etc/rc.d/openhapd ]; then
	rcctl stop openhapd 2>/dev/null || true
	rcctl disable openhapd 2>/dev/null || true
	cd /tmp/openhap-* && make uninstall 2>/dev/null || true
	# Remove config to ensure fresh installation for testing
	rm -f /etc/openhapd.conf
fi

# Change to extracted directory
cd /tmp/openhap-*

# Install dependencies
make deps

# Run make install
make install

# Create system user if not exists
id _openhap >/dev/null 2>&1 || \
	useradd -c "OpenHAP Daemon" -d /var/empty -g =uid -r 100..999 -s /sbin/nologin _openhap 2>/dev/null || true

# Add _openhap to wheel group for mdnsd socket access
# mdnsctl requires wheel group membership to access /var/run/mdnsd.sock
usermod -G wheel _openhap 2>/dev/null || true

# Set ownership on data directory
chown _openhap:_openhap /var/db/openhapd

# Copy example config if no config exists
[ -f /etc/openhapd.conf ] || cp /etc/examples/openhapd.conf /etc/openhapd.conf

# Clean up
cd /tmp && rm -rf openhap-* openhap.tar.gz

# Enable and start services
rcctl enable mosquitto
rcctl start mosquitto

# Configure and start mdnsd on the primary network interface. mdnsd
# needs an interface for multicast DNS; started without one it exits
# immediately, which later surfaces as failing mDNS integration tests.
# Prefer the default-route interface, fall back to the first UP, non
# loopback interface, and verify the daemon actually came up.
if rcctl get mdnsd >/dev/null 2>&1; then
	IFACE=$(route -n show -inet 2>/dev/null |
		awk '/^default/ { print $NF; exit }')
	[ -n "${IFACE}" ] || IFACE=$(ifconfig -a |
		awk -F: '/^[a-z].*<UP,/ && !/^(lo|enc|pflog)/ { print $1; exit }')

	if [ -n "${IFACE}" ]; then
		rcctl set mdnsd flags "${IFACE}"
		rcctl enable mdnsd
		rcctl restart mdnsd || true
		if ! rcctl check mdnsd; then
			# Surface why mdnsd would not stay up so the mDNS
			# integration tests are diagnosable from CI logs
			# instead of just reporting a missing daemon.
			echo "WARNING: mdnsd did not start on ${IFACE}; diagnostics:"
			rcctl get mdnsd || true
			ifconfig "${IFACE}" || true
			echo "-- mdnsd foreground start (2s) --"
			timeout 2 /usr/local/sbin/mdnsd -d "${IFACE}" 2>&1 |
				head -n 20 || true
		fi
	else
		echo "WARNING: no network interface found for mdnsd"
		ifconfig -a || true
	fi
fi

if [ -x /etc/rc.d/openhapd ]; then
	rcctl enable openhapd
	rcctl start openhapd
fi

sleep 2
echo "OpenHAP installed and services started"
EOF

echo "==> Provisioning complete"
