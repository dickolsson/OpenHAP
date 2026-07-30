# OpenHAP

**HomeKit Accessory Protocol for OpenBSD**

OpenHAP bridges MQTT-connected Tasmota devices to Apple HomeKit, enabling
control via the iOS Home app.

Website and manuals: <https://www.openhap.org/>

## Features

- Pairs with the iOS Home app over HAP, and keeps the session encrypted
- Tasmota thermostats, heaters, switches, sensors, lightbulbs and dimmers,
  declared in `openhapd.conf(5)`
- MQTT for device control and state
- Runs as `_openhap` from `rc.d`, under pledge(2) and unveil(2)

## Quick Start

```sh
make deps
make install
cp /etc/examples/openhapd.conf /etc/openhapd.conf
vi /etc/openhapd.conf
rcctl enable mosquitto openhapd
rcctl start mosquitto openhapd
```

See [INSTALL.md](INSTALL.md) for complete installation instructions.

## Documentation

- `openhapd(8)` - Daemon and command-line options
- `openhapd.conf(5)` - Configuration file format
- `hapctl(8)` - Control utility

## Development

See [CLAUDE.md](CLAUDE.md) for development commands, coding style, and
conventions.

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
