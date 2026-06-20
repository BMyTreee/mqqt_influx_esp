# 02 — use the influxdb3 crate instead of hand-rolled HTTP

## goal

`01_switch_to_influxdb3.md` had `src/db.rs` doing raw HTTP via `reqwest`
(building line protocol by hand, escaping tags/fields, POSTing to
`/api/v3/write/lp`). Replace all of that with the official
[`influxdb3`](https://docs.rs/influxdb3/0.2.4/influxdb3/) crate (v0.2.4),
which the maintainer (`romainsuzanne`) wrote against the InfluxDB 3 REST API.

## what changed

### `Cargo.toml`
- removed `reqwest` (no longer used directly — the crate uses reqwest 0.13
  internally).
- removed `influxdb = "0.8.0"` (v2 client, unused).
- added `influxdb3 = "0.2.4"`.
- added `chrono = "0.4"` for `Utc::now()` on the data-point builder.

### `src/db.rs`
- `Influx` struct now holds an `influxdb3::http_client::InfluxDbClient`
  (one field, not four).
- `connect()`: builds the client with `InfluxDbClientBuilder::new()
  .server_endpoint().token().database().build()`, then retries the crate's
  `client.health()` (GET `/health` with the bearer token — same
  token-validated ping the old code did by hand). Retry loop, counts, and
  delay unchanged.
- `insert_reading()`: returns `Result<(), influxdb3::Error>` (was
  `reqwest::Error`). Builds a `DataPointBuilder` — `.table(MEASUREMENT)`,
  `.tag(NODE_TAG, ..)`, `.tag(TOPIC_TAG, ..)`,
  `.field(PAYLOAD_FIELD, FieldDataType::String(json))`,
  `.datetime(Utc::now())`, `.build()` — then `client.write_one(point)`.
- deleted `build_line`, `now_nanos`, `escape_tag`, `escape_field` — the
  crate's `influx3_lp` dependency handles line-protocol escaping.
- deleted `HEALTH_PATH`, `WRITE_PATH`, `PRECISION` consts (now internal to
  the crate).
- `Reading` struct + all tag/field/measurement name consts: unchanged.

### `src/main.rs`, `src/mqtt.rs`
- unchanged. `connect()` still returns `Result<Influx, Box<dyn Error>>`;
  `insert_reading` still returns an `Err` type that implements `Display`
  (`influxdb3::Error`, via `thiserror`), so the `error = %e` log line
  compiles unchanged.

## API notes (verified against docs.rs 0.2.4)
- method names are the **non**-prefixed forms: `server_endpoint`, `token`,
  `database`, `table`, `tag`, `field`, `datetime`. (The README example on
  the crate page shows `with_server_endpoint`/`with_tag`/`with_field` —
  stale; the struct impls confirm the unprefixed names.)
- only `InfluxDbClientBuilder`, `DataPointBuilder`, `FieldDataType`, `Error`
  are re-exported at the crate root. The built client type
  `InfluxDbClient` is at `influxdb3::http_client::InfluxDbClient` (the
  `http_client` module is public).
- `InfluxDbClient::health()` exists specifically to validate the server +
  token before first use — replaces our manual `/health` GET.
- `write_one` returns `Result<Option<String>, Error>` (cluster uuid), not
  `Option<Uuid>` as the crate README snippet implies.

## validation (on mac)
- `cargo check` → clean.
- `cargo clippy --all-targets -- -D warnings` → clean.
- `cargo fmt --check` → clean.

## not yet validated end-to-end
- first real run on lxn is the checkpoint. Verify:
  1. `health()` against the running 3.10 core succeeds with the admin token,
  2. a first MQTT reading lands as a `readings` row with the expected tags +
     `payload` string field,
  3. timestamps are at nanosecond precision (the crate sends `DateTime<Utc>`
     which it converts to ns).
