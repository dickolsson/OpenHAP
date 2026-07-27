# OpenHAP

**HomeKit Accessory Protocol for OpenBSD**

OpenHAP bridges MQTT-connected Tasmota devices to Apple HomeKit, enabling
control via the iOS Home app.

Website and manuals: <https://www.openhap.org/>

## Features

- **HomeKit**: Full HAP implementation with secure pairing
- **Crypto**: SRP-6a, Ed25519, X25519, ChaCha20-Poly1305
- **Thermostats**: Control Tasmota heaters with temperature sensors
- **MQTT**: Connects HomeKit to MQTT-based devices
- **OpenBSD**: Native with pledge(2)/unveil(2) support

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
