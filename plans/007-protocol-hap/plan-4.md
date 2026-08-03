# Phase 4 — The wire engine

This phase is the split of `OpenHAP::HAP` (1440 lines) into the sans-IO
`Protocol::HAP::Server` and the host `OpenHAP::Server`. The HTTP codec moves
into the library first, because the engine is its main consumer.

## Tasks

### 4.1 Move FuguLib::HTTP to Protocol::HAP::HTTP

- `git mv`, rename the package. Only OpenHAP code uses the codec;
  `FuguLib::Proxy` keeps its own minimal parser.
- Add `build_event($body)`: the EVENT/1.0 message builder, today an inline
  string in `OpenHAP::HAP::send_event` [HAP-HTTP §14].
- Update the users: `OpenHAP::HAP`, `OpenHAP::Test::Controller`,
  `OpenHAP::Test::Integration`, `t/conformance/hap-http.t` and the two exchange
  tests.
- Move `t/fugulib/http.t` to `t/protocol/http.t`. Delete `man/fugulib/HTTP.3p`,
  remove it from `MAN3P`, update the `.Xr` cross-references,
  `web/fugulib.body.html`, and any page assertion in `t/web/site.t`. Write the
  `Protocol/HAP/HTTP.pod` sidecar.

### 4.2 Extract Protocol::HAP::Server

The engine takes the protocol half of `OpenHAP::HAP`:

- Constructor: `name`, `pin`, `setup_id`, `category`, and the host contracts
  `store`, `logger`, `output`, `after`, `cancel`, `on_pairing_changed` from the
  design. The engine loads or generates the accessory identity through the
  store, builds the bridge, and owns the `Pairing` instance.
- Connection API: `session_open`, `receive`, `session_close`, per the design's
  connection contract. The read buffer, the 64 KB bound, decryption, HTTP
  parsing, and dispatch move inside. `receive` emits responses through `output`
  and returns 1, or undef on a fatal condition.
- Endpoints: `/pair-setup`, `/pair-verify`, `/identify`, `/pairings` (add,
  remove, list), `/accessories`, `/characteristics` GET and PUT, `/prepare`. The
  handlers move with their behavior intact; the logging, storage, and JSON calls
  change spelling. `JSON::XS` becomes core `JSON::PP` here — the boundary test
  forbids `JSON::XS` under `lib/Protocol/`.
- Events: the subscription registry, coalescing through `after`/`cancel`,
  `queue_event`, `flush_events`, and `send_event` over `output`.
- Identity and discovery: `is_paired`, `get_config_number`,
  `update_config_number`, `get_device_id`, `mdns_txt_records`. The `.`-joined
  string form does not move: it is mdnsd's format.
- Pairing-state changes call `on_pairing_changed` instead of touching mDNS.
- `add_accessory`, `get_bridged_accessories` pass-throughs for the host and the
  device loader.

### 4.3 Create OpenHAP::Server, delete OpenHAP::HAP

The host takes the other half:

- The listening socket, `accept`, per-connection reads and writes, and the
  fileno-to-session map, on `FuguLib::EventLoop`. The host closes a connection
  when `receive` returns undef and calls `session_close`.
- The MQTT tick and reconnect timers, and accessory resubscription.
- The mDNS handle: publish at startup, and on `on_pairing_changed` re-advertise
  with `FuguLib::MDNS::format_txt` over the engine's records.
- `control_status` and `control_devices`, composing engine introspection with
  host state (uptime, MQTT, mDNS, connection count).
- `run`, `stop`, `shutdown`, and the `listen` bootstrap.

### 4.4 FuguLib::MDNS::format_txt

- Add `format_txt(%records)`: sorted keys, `key=value`, joined with `.`
  [MDNS-Control §5]. Move the join out of the engine.
- Extend `t/fugulib/mdns.t` and `man/fugulib/MDNS.3p`.

### 4.5 Rewire the entry points

- `bin/openhapd` builds `OpenHAP::Server`, which builds the engine with
  `OpenHAP::Storage`, `FuguLib::Log->default`, and the loop's timer hooks. The
  pledge and unveil sequence, and the preload call, do not change.
- `bin/hapctl` is untouched: it speaks to the control socket.
- Check `man/openhap/openhapd.8` and the `openhapd`/`hapctl` skills for
  module-name references; update what names `OpenHAP::HAP`.

### 4.6 Tests

- Split `t/openhap/hap.t`: engine behavior becomes `t/protocol/server.t`, driven
  sans-IO over `Store::Memory` with captured `output`; host wiring becomes
  `t/openhap/server.t`.
- Rework the transport of `t/conformance/hap-http.t`, `hap-mdns.t`, and the two
  exchange tests. They drive the private `$hap->_dispatch` in-process today, and
  this phase deletes it. The replacement is the public engine API:
  `session_open`, `receive`, and captured `output`. The assertions and their
  citations stay as they are.
- `t/openhap/integration/` names the daemon, not the modules; verify, and update
  only if a test names `OpenHAP::HAP`.

## Deliverables

- `lib/Protocol/HAP/Server.pm` and `HTTP.pm` with `.pod` sidecars.
- `lib/OpenHAP/Server.pm` with a `.pod` sidecar; `lib/OpenHAP/HAP.pm` and its
  pod deleted.
- `t/protocol/server.t`, `t/protocol/http.t`, `t/openhap/server.t`.
- Updated `bin/openhapd`, `FuguLib::MDNS`, `Makefile`, man pages, web body.

## Acceptance criteria

- `make check` passes; `make spec-coverage` reports no stale citations.
- `grep -r 'OpenHAP::HAP\b\|FuguLib::HTTP' lib bin t` finds nothing.
- `t/protocol/server.t` runs the full pair-setup, pair-verify, and encrypted
  request flow without one socket.
- `t/protocol/boundary.t` passes with the engine in place.
- `make integration` passes in the VM before the phase merges: the daemon
  pledges, publishes, pairs, and serves as before.
