# 01 — switch mqqt_influx_esp from InfluxDB v2 to InfluxDB 3 Core

## goal

The InfluxData apt repo for v2 broke on lxn (`NO_PUBKEY DA61C26A0585BD3B` —
the `stable` InRelease is signed by a key not in the published
`influxdata-archive_compat.key`, so the pinned-sha apt route is unfixable
without chasing rotating keys). Pivot the whole stack to **InfluxDB 3 Core**,
installed from the official binary tarball (sha256 sidecar verified), run as a
systemd service.

## what changed

### `setup_lxn.sh`
- `INFLUXDB3_VERSION="3.10.0"` const.
- env prompts: dropped `INFLUX_USER/PASSWORD/ORG/BUCKET/TOKEN`; added
  `INFLUX_DATABASE` (default `listen_lxn`). `INFLUX_PORT` default `8086` → `8181`.
- `install_influx()`: removed the apt repo + `influxdb2`/`influxdb2-cli` path.
  Now detects arch (`linux_amd64` / `linux_arm64`), downloads
  `dl.influxdata.com/.../influxdb3-core-<ver>_<arch>.tar.gz` + `.sha256`,
  verifies sha256, extracts the binary to `/usr/local/bin/influxdb3`, writes a
  systemd unit (`influxdb3 serve --node-id=node0 --http-bind=0.0.0.0:<port>
  --object-store=file --data-dir=/var/lib/influxdb3`), enables + starts it,
  waits on `/health`.
- `setup_influx()`: creates the admin token via
  `POST /api/v3/configure/token/admin` (409 = already exists → die with reset
  hint), persists to `/root/.influx_lxn_token`; best-effort
  `influxdb3 create database` (v3 also auto-creates on first write).
- `write_env()`: `.env` now has `INFLUX_DATABASE` instead of `INFLUX_ORG/BUCKET`.

### `src/db.rs`
- `WRITE_PATH` `/api/v2/write` → `/api/v3/write/lp`.
- env: `INFLUX_ORG`/`INFLUX_BUCKET` → `INFLUX_DATABASE`.
- `Influx` struct: `org`/`bucket` → `database`.
- write query params: `org`/`bucket` → `db`; auth header `Token` → `Bearer`.
- line-protocol building / escaping / `Reading` struct: unchanged.

### `README.md`
- v2 → 3 Core throughout; env table updated; setup step text updated.

## validation (on mac)
- `cargo check`, `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`
  → all clean.
- `bash -n setup_lxn.sh` → ok.

## not yet validated end-to-end
- First real run on lxn is the checkpoint. Specifically verify on lxn:
  1. the tarball URL + sha256 sidecar resolve for the detected arch,
  2. `POST /api/v3/configure/token/admin` returns `{"token":"..."}`,
  3. a first MQTT reading actually lands: write endpoint is
     `/api/v3/write/lp?db=<db>&precision=ns` with `Authorization: Bearer <token>`.
     If that endpoint/auth is rejected by this build, it's isolated to
     `WRITE_PATH` and the `Bearer` header in `src/db.rs` (2-line fix).

## follow-ups / open questions
- **Python 3.13 runtime dependency:** the influxdb3 3.10.0 binary is dynamically
  linked against `libpython3.13.so.1.0`, which Debian 12 does NOT ship (it has
  3.11). `ensure_python313()` builds Python 3.13 from source (pinned
  `PYTHON_VERSION="3.13.1"`) with `--enable-shared` so `libpython3.13.so.1.0`
  lands in `/usr/local/lib` and `ldconfig` resolves it. ~3–5 min compile, skipped
  on re-runs. If a future influxdb3 release drops the Python link, this step can
  be removed. Alternative if the build ever breaks: run the `influxdb:3-core`
  Docker image instead (bundles Python).
- **`/health` requires a token in 3.10** (returns 401 `MissingToken` on every
  endpoint, including `/health`). `install_influx()` health loop now accepts
  `200` OR `401` as "up". `db::connect()` sends `Authorization: Bearer <token>`
  on its `/health` ping so the token is validated before the first write.
  Bootstrap still works: `POST /api/v3/configure/token/admin` is the one
  unauthenticated endpoint.
- v3 Core has no fixed-size string-field limit like v2's ~64 KB, but very large
  JSON payloads still bloat the Parquet files; current ESP readings are tiny.
- Whole JSON stored as one string field — fine for raw capture, bad for per-sensor
  queries. Flatten known fields into separate line-protocol fields later if needed.
- `INFLUXDB3_VERSION` is pinned; bump deliberately and re-verify sha on upgrade.
