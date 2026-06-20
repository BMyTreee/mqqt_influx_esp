# mqqt_influx_esp

MQTT → InfluxDB 3 Core listener. Subscribes to a sensor topic and writes each
payload (line protocol) into a local InfluxDB 3 database. Mirrors the
`listen_lxn_mqtt` shape but swaps Postgres for InfluxDB.

## run on lxn (Linux host)

```bash
git clone <this-repo>
cd mqqt_influx_esp
bash setup_lxn.sh
```

The script (run as root):
1. opens local sshd for password access
2. installs build deps + tmux via apt
3. installs + starts InfluxDB 3 Core locally (binary, systemd), creates the
   admin token + database (token persisted to `/root/.influx_lxn_token`)
4. ensures the Rust toolchain
5. writes `.env` with InfluxDB + MQTT endpoints
6. `cargo build --release`
7. starts the binary in a tmux session named `influx_lxn`

## env vars (`.env`)

| var              | purpose                                  |
| ---------------- | ---------------------------------------- |
| `INFLUX_URL`     | InfluxDB 3 base URL                      |
| `INFLUX_DATABASE`| target database                          |
| `INFLUX_TOKEN`   | admin / write token                      |
| `MQTT_HOST`      | MQTT broker host                         |
| `MQTT_PORT`      | MQTT broker port                         |
| `MQTT_TOPIC`     | topic filter (default `mini_c3/sensor`) |

## data model

One measurement, written via line protocol:

```
readings,node_id=<mac>,topic=<escaped_topic> payload="<json>" <ts_ns>
```

`payload` is the raw MQTT payload serialized as a JSON string field.
