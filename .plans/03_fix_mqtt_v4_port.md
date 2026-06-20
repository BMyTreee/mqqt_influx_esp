# 03 — fix MQTT v5/v4 protocol mismatch (InvalidProtocolLevel(4))

## symptom

rumqttd logs, repeated every reconnect attempt:
```
ERROR remote_link{tenant_id=None}: rumqttd::server::broker:
  Error while handling MQTT connect packet error=Network(Protocol(InvalidProtocolLevel(4)))
INFO  rumqttd::server::broker: accept name="mqtt-tcp-v5" addr=192.168.1.94:48894 count=87281
```
client side: `WARN mqqt_influx_esp::mqtt: mqtt connection error
error=Io(Custom { kind: ConnectionAborted, error: "connection closed by peer" })`
in a tight loop, then Ctrl-C.

## root cause

rumqttd separates MQTT versions by **config section name prefix**, not by
per-connection negotiation:
- `[v4.x]` sections accept **MQTT 3.1.1** (CONNECT protocol level = 4)
- `[v5.x]` sections accept **MQTT v5**     (CONNECT protocol level = 5)

A `[v5.x]` listener hard-rejects a protocol-level-4 CONNECT — hence
`InvalidProtocolLevel(4)`.

`rumqttc 0.24` is a **v3.1.1-only** client (no protocol-version setter on
`MqttOptions`, see docs.rs). It always sends protocol level 4. So it cannot
ever connect to a `[v5.x]` listener.

The stock `rumqttd.toml` ships two listeners:
- `[v4.1]` on `0.0.0.0:1883`  ← v3.1.1
- `[v5.1]` on `0.0.0.0:1884`  ← v5

Both `main.rs` (`MQTT_PORT_DEFAULT = 1884`) and `setup_lxn.sh`
(`MQTT_PORT:-1884`) defaulted to the **v5** port. That port only accepts
v5, rumqttc only speaks v4 → every CONNECT rejected → the flapping loop.

## fix

Point the client at the v3.1.1 listener (1883), not the v5 listener (1884):

- `src/main.rs`: `MQTT_PORT_DEFAULT: u16` `1884` → `1883`.
- `setup_lxn.sh`: `MQTT_PORT="${MQTT_PORT:-1883}"`.
- `.env` (on lxn): if a previous `setup_lxn.sh` wrote `MQTT_PORT=1884`,
  re-run `setup_lxn.sh` (or edit `.env` to `MQTT_PORT=1883`). The env var
  wins over the code default, so an existing `.env` with 1884 will still
  override the new default until refreshed.

## why not switch the client to v5

rumqttc 0.24 has no v5 path. The alternatives (paho-mqtt, rmqtt) are full
rewrites of `src/mqtt.rs` and add a bigger dep tree. Nothing in the current
payload-as-string design needs v5 features, so staying on v3.1.1 is the
lean choice — the fix belongs on the port default, not the client crate.

## why not reconfigure the broker

Would also work (add a `[v4.x]` listener, or change the operator's named
listener to a `[v4.x]` section). But the broker already ships a v4 listener
on 1883 — using it is zero-config on the broker side and one-line on the
client side. If a deployment legitimately needs 1884, the operator must
make 1884 a `[v4.x]` listener; that's a broker-side decision.

## validation (on mac)
- `cargo clippy --all-targets -- -D warnings` → clean.
- `bash -n setup_lxn.sh` → ok.

## not yet validated end-to-end
- first run on lxn after updating `.env` / re-running `setup_lxn.sh`: expect
  a clean `INFO ... "listening"` and `rumqttd ... accept name="v4-1" ...`
  on the broker, no more `InvalidProtocolLevel` errors.
