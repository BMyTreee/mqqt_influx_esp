# 00 — port listen_lxn_mqtt to InfluxDB v2 (mqqt_influx_esp)

## goal

`listen_lxn_mqtt` stores MQTT readings into Postgres. Build a sibling project
`mqqt_influx_esp` that stores the same readings into a **local InfluxDB v2**
instance running on the Linux host (lxn). Code is written on mac, deployed to
lxn via `git clone` + `bash setup_lxn.sh`.

## what changed

### Rust (mirror of listen_lxn_mqtt, PG → Influx)

- `Cargo.toml` — swapped `sqlx` for `reqwest` (rustls, no openssl).
  Kept `rumqttc`, `dotenvy`, `mac_address`, `tokio`, `serde_json`, `tracing*`.
- `src/main.rs` — same shape as reference; `db::connect()` returns an
  `Influx` client instead of a `PgPool`.
- `src/mqtt.rs` — identical to reference (only depends on `db::Reading`).
- `src/db.rs` — InfluxDB v2 writer via line protocol:
  - `connect()` pings `/health` with retry loop (PG version retried the pool
    connect; same idea).
  - `insert_reading()` POSTs to `/api/v2/write?org=&bucket=&precision=ns`
    with `Authorization: Token <token>` and a line-protocol body.
  - Line shape: `readings,node_id=<mac>,topic=<esc> payload="<json>" <ts_ns>`.
  - Tag/field escaping for line protocol (`,`, `=`, ` ` for tags; `"`, `\`
    for string field values).
  - No unused `const`s (no `#[allow(dead_code)]`).

### Linux bootstrap (`setup_lxn.sh`)

Mirrors `listen_lxn_mqtt/setup_lxn.sh` and adds:
- adds InfluxData apt repo (sha256-verified key, signed-by keyring),
  installs `influxdb2` + `influxdb2-cli`,
- `systemctl enable --now influxdb`,
- waits for `/health` (60s),
- runs `influx setup` **only if** `GET /api/v2/setup` returns `"allowed":true`
  (idempotent on re-runs),
- persists the admin token to `/root/.influx_lxn_token` (chmod 600) so re-runs
  don't lose it,
- writes `.env` with `INFLUX_URL/ORG/BUCKET/TOKEN` + `MQTT_*`,
- builds + runs in tmux session `influx_lxn` (same pattern as reference).

Added a root-check in `preflight` since InfluxDB setup needs root.

### docs

- `README.md` — run instructions + env table + data model.
- `.gitignore` — `/target`, `.env`.

## validation (on mac)

- `cargo check` → ok
- `cargo clippy --all-targets -- -D warnings` → clean
- `cargo fmt --check` → ok
- `bash -n setup_lxn.sh` → ok

Not validated end-to-end on lxn (no Linux host available here). First real run
on lxn is the next checkpoint.

## follow-ups / open questions

- InfluxDB string field max length is ~64 KB; large JSON payloads would be
  truncated. Current ESP readings are tiny, so this is fine for now.
- The whole JSON is stored as one string field — easy but not great for
  querying individual sensor values. If we want per-field queries later, we
  should flatten known payload fields into separate line-protocol fields.
- `setup_lxn.sh` requires root and edits `/etc/ssh/sshd_config` (same as the
  reference script). Keep that in mind on hardened hosts.
- Repo not yet `git init`'d — needs `git init` + remote before clone-on-lxn
  works.
