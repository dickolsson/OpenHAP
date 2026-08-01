# OpenHAP

**HomeKit Accessory Protocol for OpenBSD**

OpenHAP connects MQTT-connected Tasmota devices to Apple HomeKit. You can
control the devices with the iOS Home app.

Website and manuals: <https://www.openhap.org/>

## Features

- OpenHAP pairs with the iOS Home app through HAP and encrypts the session
- You declare Tasmota thermostats, heaters, switches, sensors, lightbulbs, and
  dimmers in `openhapd.conf(5)`
- OpenHAP uses MQTT to control the devices and to read their state
- The daemon runs as the `_openhap` user from `rc.d`, under pledge(2) and
  unveil(2)

## Quick Start

```sh
make deps
make install
cp /etc/examples/openhapd.conf /etc/openhapd.conf
vi /etc/openhapd.conf
rcctl enable mosquitto openhapd
rcctl start mosquitto openhapd
```

See [INSTALL.md](INSTALL.md) for the complete installation instructions.

## Documentation

- `openhapd(8)` - the daemon and its command-line options
- `openhapd.conf(5)` - the configuration file format
- `hapctl(8)` - the control utility

## Development

See [CLAUDE.md](CLAUDE.md) for the development commands, the coding style, and
the conventions.

## Architecture

```
iOS Home App
     │
     │ TCP/TLS (HAP)
     ▼
┌─────────────┐     ┌───────────┐     ┌─────────────┐
│  openhapd   │◄───►│ mosquitto │◄───►│   Tasmota   │
│  :51827     │     │  :1883    │     │   Devices   │
└─────────────┘     └───────────┘     └─────────────┘
```

## License

ISC License. See [LICENSE](LICENSE).
