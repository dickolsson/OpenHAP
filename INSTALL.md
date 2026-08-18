# Installation

This document tells you how to install OpenHAP on OpenBSD. See
`openhapd.conf(5)` for the configuration options. See `openhapd(8)` and
`hapctl(8)` for the command-line options.

## Requirements

- OpenBSD 7.4 or a later version
- Perl 5.36 or a later version (base system)
- The [Fugu](https://github.com/FuguBSD/Fugu) Perl library — `make deps`
  installs it from its latest GitHub release

## Dependencies

The `make deps` command installs the runtime dependencies, the Fugu library
among them. The manifests under `deps/` list them for each platform, for
example, `deps/OpenBSD.txt`.

## Install

```sh
git clone https://github.com/dickolsson/openhap.git
cd openhap
make deps
doas make install
```

## Setup

```sh
# Create the system user
doas useradd -c "OpenHAP" -d /var/empty -g =uid -r 100..999 -s /sbin/nologin _openhap
doas usermod -G wheel _openhap  # Necessary for access to the mdnsd socket
doas chown _openhap:_openhap /var/db/openhapd

# Configure the daemon
doas cp /etc/examples/openhapd.conf /etc/openhapd.conf
doas vi /etc/openhapd.conf

# Do a check of the configuration
doas openhapd -n

# Enable mDNS (replace vio0 with the name of your interface)
echo 'multicast=YES' | doas tee -a /etc/rc.conf.local
echo 'mdnsd_flags=vio0' | doas tee -a /etc/rc.conf.local

# Enable and start the services
doas rcctl enable mosquitto mdnsd openhapd
doas rcctl start mosquitto mdnsd openhapd
```

## Firewall

Add these rules to `/etc/pf.conf`:

```
pass in on $lan_if proto tcp to port 51827  # HAP
pass in on $lan_if proto udp to port 5353   # mDNS
```

## Checks

Make sure that the daemon runs and that it loaded the devices:

```sh
hapctl status
hapctl devices
```

## Upgrade

```sh
doas rcctl stop openhapd
cd openhap && git pull
doas make install
doas rcctl start openhapd
```

## Uninstall

```sh
doas rcctl stop openhapd
doas rcctl disable openhapd
cd openhap
doas make uninstall
# If it is necessary, remove the configuration and the data
doas rm -f /etc/openhapd.conf
doas rm -rf /var/db/openhapd
doas userdel _openhap
```

## Problems

**The daemon does not start:**

```sh
openhapd -n -c /etc/openhapd.conf  # Do a check of the configuration
tail /var/log/daemon | grep openhap
```

**The iOS Home app does not show the bridge:**

```sh
rcctl check mdnsd
mdnsctl browse
nc -zv <ip> 51827
```

**MQTT does not operate correctly:**

```sh
rcctl check mosquitto
mosquitto_sub -h localhost -t '#' -v
```
