# 01 — fix mqtt "connection closed by peer" (client id collision)

## symptom

```
WARN mqqt_influx_esp::mqtt: mqtt connection error
    error=Io(Custom { kind: ConnectionAborted, error: "connection closed by peer" })
```
Repeated in a loop, then `^C`.

## diagnosis

Compared `mqqt_influx_esp/src/mqtt.rs` against `listen_lxn_mqtt/src/mqtt.rs`
(via `diff`, not `read_file` which returned stale content). Findings:

- `mqqt_influx_esp` already had the **improved** mqtt code (4-arg `run` with
  port, tracing, error surfacing). `listen_lxn_mqtt` still has the old
  3-arg version that silently swallows errors with `let Ok(...) else continue`.
- Functional connection params are otherwise identical: keep-alive 5s,
  QoS AtLeastOnce, same broker.
- **Both projects built the client id as `listen_<mac>`.** On one host the MAC
  → `listener_id` is the same, so both processes advertise the same MQTT
  client id to the broker.
- With clean-session semantics the broker only allows one live connection per
  client id. When the second process connects, the broker disconnects the
  first → that side sees `Io(ConnectionAborted, "connection closed by peer")`.
  rumqttc then auto-reconnects and kicks the other side. Endless warn loop.

This is a classic rumqttc "connection closed by peer" loop and matches the
repeated-warning symptom exactly.

## fix

`mqqt_influx_esp/src/mqtt.rs`:
- added `const CLIENT_ID_PREFIX: &str = "influx_";`
- client id is now `format!("{CLIENT_ID_PREFIX}{listener_id}")` → `influx_<mac>`
  instead of `listen_<mac>`. No longer collides with `listen_lxn_mqtt`.

No change to listen_lxn_mqtt.

## validation (mac)

- `cargo check` → ok
- `cargo clippy --all-targets -- -D warnings` → clean
- `cargo fmt --check` → ok

Not validated end-to-end on lxn. Re-run there to confirm the warn loop stops.

## if it still fails after this

Other things to check on the broker side (in order of likelihood):
1. Confirm the broker really is on port `1884` (both `main.rs`
   `MQTT_PORT_DEFAULT` and `setup_lxn.sh` default). Standard MQTT is 1883.
2. Confirm no auth / ACL is required — `MqttOptions::new` passes no
   credentials. If the broker requires them, add `options.set_credentials(...)`.
3. Confirm the broker accepts MQTT 3.1.1 — rumqttc 0.24 defaults to v4
   (3.1.1). If the broker is v5-only the connection gets dropped the same way.
