# 05 — flatten temp/hum into numeric fields for Grafana

## symptom

After 04, writes succeeded, but Grafana showed
**"Data is missing a number field"**. `SHOW FIELD KEYS` returned only
`payload (string)` — the entire MQTT payload was stored as one JSON string,
so InfluxDB had nothing numeric for `mean("temp")` / `mean("hum")` to
aggregate.

## root cause

The old `insert_reading` wrote one field:
`payload="{\"temp\":25.0,\"hum\":79.6}"`. InfluxDB types that as a string,
which Grafana cannot chart.

## fix

`src/db.rs` — extract the known numeric keys from the JSON `Value` and add
them as separate `FieldDataType::Float` fields, while keeping `payload` for
raw capture. Wire shape now (verified by the test):
```
readings,node_id=min,topic=mini_c3/sensor payload="{\"hum\":79.6,\"temp\":25.0}",temp=25,hum=79.6 <ts>
```
(HashMap ordering — field order is not significant to InfluxDB/Grafana.)

Decisions vs. the user's suggested snippet:
- **`FieldDataType::Float64` → `FieldDataType::Float`**: the crate's enum
  has no `Float64` variant (verified in 0.2.4 source). The variant is
  `Float(f64)`.
- **`unwrap_or(0.0)` → conditional add**: writing a fake 0.0 when the ESP
  omits a value would skew `mean()`/`sum()` in Grafana. Instead we only add
  the field when `payload.get(key).and_then(Value::as_f64)` returns `Some`.
- **kept `payload`**: plan 00's design was raw capture; the string field is
  harmless to Grafana now that numeric fields exist, and it survives future
  ESP schema additions. Easy to drop later if storage matters.

Refactor: split the point construction out of `insert_reading` into a pure
`build_point(r: &Reading) -> Result<DataPoint, influxdb3::Error>` so the
unit test can exercise the exact wire path without HTTP. `DataPoint` is at
`influxdb3::data_point::DataPoint` (not re-exported at the crate root).

`escape_tag` / `escape_field` / the plan-04 escaping workaround: still
needed (the `payload` string field still has inner quotes). Unchanged.

Consts added: `TEMP_FIELD = "temp"`, `HUM_FIELD = "hum"` (per the
"no hard code for names" rule).

## Grafana query (after rebuild + restart)

```sql
SELECT mean("temp") FROM "readings" WHERE $timeFilter GROUP BY time($__interval)
SELECT mean("hum")  FROM "readings" WHERE $timeFilter GROUP BY time($__interval)
```
Or with the SQL data source: `SELECT mean(temp), mean(hum) FROM readings WHERE $timeFilter GROUP BY time($__interval)`.

## validation (on mac)
- `cargo test` → `point_has_numeric_temp_hum_and_escaped_payload` passes.
  Asserts temp/hum are unquoted numeric, not string-typed, and `payload`
  quotes are still escaped.
- `cargo clippy --all-targets -- -D warnings` → clean.
- `cargo fmt --check` → clean.
- Confirmed wire bytes via `to_line_protocol()` (test printed them):
  `...payload="{\"hum\":79.6,\"temp\":25.0}",temp=25,hum=79.6 <ts>`.

## data migration note
Old rows in InfluxDB still only have `payload` (no `temp`/`hum`). They will
not be chartable. New rows from the rebuilt binary onward will be. If you
need history, query `payload` and re-parse — or just let new data age in.

## not yet validated end-to-end
First real ESP reading on lxn after `cargo build --release` + tmux restart.
Expect `SHOW FIELD KEYS` to show `hum (float)`, `payload (string)`,
`temp (float)`, and the Grafana panel to plot.
