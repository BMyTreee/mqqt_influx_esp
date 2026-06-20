# 04 — influxdb3 0.2.4 doesn't escape string fields → re-add our own escaping

## symptom

After 03 fixed the MQTT port, writes land but InfluxDB rejects every line:
```
WARN mqqt_influx_esp: insert failed ... error=HTTP 400 Bad Request
  response: {"error":"partial write of line protocol occurred",
  "data":[{"error_message":"Could not parse entire line.
  Found trailing content: `hum\":79.6,...`","line_number":1,
  "original_line":"readings,node_id=min"}]}
```
(Same payload every reading — JSON like `{"temp":25.0,"hum":79.6,...}` produced
by the ESP32 via manual `extend_from_slice`.)

## root cause (read the crate source, not the docs)

`influxdb3 0.2.4` `src/data_point.rs` `DataPoint::to_line_protocol`:
```rust
FieldDataType::String(value) => {
    resulting_line.push_str(format!("{}=\"{}\"", field_key, value).as_str());
}
```
It wraps the value in `"..."` but **does not escape** inner `"` or `\`.
There is a literal `// TODO` at the top of the file listing exactly the
escaping the spec requires (`\"`, `\\`) and saying it isn't implemented.
Tag values are equally unescaped (`format!(",{}={}", tag_key, tag_value)`).

So our line went out as:
```
readings,node_id=mini_c3,topic=mini_c3/sensor payload="{"temp":25.0,"hum":79.6}" <ts>
```
InfluxDB opens the string at the first `"`, the unescaped `"` before `temp`
closes it, and the rest is "trailing content" → 400.

## fix

`src/db.rs` — escape the values ourselves before handing them to the
builder, exactly per the line-protocol spec:
- tag values: escape `,` `=` ` `  (`escape_tag`)
- string field values: escape `"` `\`  (`escape_field`)

Both helpers are the same ones deleted in plan 02; they come back, now
applied to the crate's builder inputs instead of to a hand-rolled body.

No double-escape risk today (the crate adds zero escaping). If a future
influxdb3 release implements the TODO and starts escaping, these helpers
would double-escape — flagged in a comment in `insert_reading`; revisit on
upgrade.

Added `db::tests::payload_field_is_escaped_for_line_protocol` as a
regression pin: it runs the real `DataPointBuilder` → `to_line_protocol()`
path and asserts the inner quotes are backslash-escaped and no unescaped
`"` leaks. Field order is unspecified (crate uses `HashMap`) so the test
checks each key independently rather than a whole-line substring.

## validation (on mac)
- `cargo test` → 1 passed.
- `cargo clippy --all-targets -- -D warnings` → clean.
- `cargo fmt --check` → clean.

## not yet validated end-to-end
- first MQTT reading on lxn after rebuild: expect `INFO ... "stored reading"`
  and the row queryable as `readings` with `node_id`/`topic` tags and a
  `payload` string field containing the original JSON.

## open question
The crate bug is broader than payload escaping — any tag value with
`,`/`=`/space would also break. We escape tags too, so we're covered for
arbitrary `node_id`/`topic`. Worth filing upstream (the TODO is in their
source).
