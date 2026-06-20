use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::Value;
use tokio::time::sleep;
use tracing::{info, warn};

const CONNECT_RETRIES: u32 = 10;
const RETRY_DELAY_SECS: u64 = 3;
const HEALTH_PATH: &str = "/health";
const WRITE_PATH: &str = "/api/v3/write/lp";
const PRECISION: &str = "ns";
const MEASUREMENT: &str = "readings";
const NODE_TAG: &str = "node_id";
const TOPIC_TAG: &str = "topic";
const PAYLOAD_FIELD: &str = "payload";

pub struct Reading {
    pub node_id: String,
    pub topic: String,
    pub payload: Value,
}

pub struct Influx {
    url: String,
    database: String,
    token: String,
    client: reqwest::Client,
}

pub async fn connect() -> Result<Influx, Box<dyn std::error::Error>> {
    let url = std::env::var("INFLUX_URL").expect("INFLUX_URL not set");
    let database = std::env::var("INFLUX_DATABASE").expect("INFLUX_DATABASE not set");
    let token = std::env::var("INFLUX_TOKEN").expect("INFLUX_TOKEN not set");
    let client = reqwest::Client::builder().build()?;

    let base = url.trim_end_matches('/').to_string();
    let health = format!("{base}{HEALTH_PATH}");

    // InfluxDB may not be up yet (concurrent boot, restart, etc.) — ping until reachable.
    for attempt in 1..=CONNECT_RETRIES {
        match client.get(&health).bearer_auth(&token).send().await {
            Ok(resp) if resp.status().is_success() => {
                info!(attempt, "influx connected");
                return Ok(Influx {
                    url: base,
                    database,
                    token,
                    client,
                });
            }
            Ok(resp) => warn!(attempt, status = %resp.status(), "influx not ready, retrying"),
            Err(e) => {
                warn!(attempt, retries = CONNECT_RETRIES, error = %e, "influx ping failed, retrying")
            }
        }
        sleep(Duration::from_secs(RETRY_DELAY_SECS)).await;
    }
    Err(format!("influx not reachable at {health} after {CONNECT_RETRIES} attempts").into())
}

pub async fn insert_reading(influx: &Influx, r: &Reading) -> Result<(), reqwest::Error> {
    let line = build_line(r);
    let endpoint = format!("{}{WRITE_PATH}", influx.url);

    influx
        .client
        .post(endpoint)
        .query(&[("db", influx.database.as_str()), ("precision", PRECISION)])
        .header("Authorization", format!("Bearer {}", influx.token))
        .header("Content-Type", "text/plain; charset=utf-8")
        .header("Accept", "application/json")
        .body(line)
        .send()
        .await?
        .error_for_status()?;

    Ok(())
}

// readings,node_id=<mac>,topic=<escaped> payload="<escaped json>" <ts_ns>
fn build_line(r: &Reading) -> String {
    let ts = now_nanos();
    let payload = r.payload.to_string();
    format!(
        "{MEASUREMENT},{NODE_TAG}={node},{TOPIC_TAG}={topic} {PAYLOAD_FIELD}=\"{payload}\" {ts}",
        node = escape_tag(&r.node_id),
        topic = escape_tag(&r.topic),
        payload = escape_field(&payload),
    )
}

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

// tag keys/values, field keys: escape comma, equals, space
fn escape_tag(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            ',' | '=' | ' ' => out.push('\\'),
            _ => {}
        }
        out.push(c);
    }
    out
}

// string field value: escape double-quote and backslash
fn escape_field(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' | '\\' => out.push('\\'),
            _ => {}
        }
        out.push(c);
    }
    out
}
