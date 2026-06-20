use std::time::Duration;

use chrono::Utc;
use influxdb3::http_client::InfluxDbClient;
use influxdb3::{DataPointBuilder, FieldDataType, InfluxDbClientBuilder};
use serde_json::Value;
use tokio::time::sleep;
use tracing::{info, warn};

const CONNECT_RETRIES: u32 = 10;
const RETRY_DELAY_SECS: u64 = 3;
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
    client: InfluxDbClient,
}

pub async fn connect() -> Result<Influx, Box<dyn std::error::Error>> {
    let url = std::env::var("INFLUX_URL").expect("INFLUX_URL not set");
    let database = std::env::var("INFLUX_DATABASE").expect("INFLUX_DATABASE not set");
    let token = std::env::var("INFLUX_TOKEN").expect("INFLUX_TOKEN not set");

    let client = InfluxDbClientBuilder::new()
        .server_endpoint(&url)
        .token(&token)
        .database(&database)
        .build()?;

    // InfluxDB may not be up yet (concurrent boot, restart, etc.) — ping until reachable.
    for attempt in 1..=CONNECT_RETRIES {
        match client.health().await {
            Ok(()) => {
                info!(attempt, "influx connected");
                return Ok(Influx { client });
            }
            Err(e) => warn!(
                attempt,
                retries = CONNECT_RETRIES,
                error = %e,
                "influx not ready, retrying"
            ),
        }
        sleep(Duration::from_secs(RETRY_DELAY_SECS)).await;
    }

    Err(format!("influx not reachable after {CONNECT_RETRIES} attempts").into())
}

pub async fn insert_reading(influx: &Influx, r: &Reading) -> Result<(), influxdb3::Error> {
    // influxdb3 0.2.4's DataPointBuilder does NOT escape tag values or string
    // field values (see its `TODO` in data_point.rs), so we escape per the
    // line-protocol spec ourselves. If the crate ever implements escaping,
    // these helpers become a double-escape — revisit on upgrade.
    let point = DataPointBuilder::new()
        .table(MEASUREMENT)
        .tag(NODE_TAG, &escape_tag(&r.node_id))
        .tag(TOPIC_TAG, &escape_tag(&r.topic))
        .field(
            PAYLOAD_FIELD,
            FieldDataType::String(escape_field(&r.payload.to_string())),
        )
        .datetime(Utc::now())
        .build()?;

    influx.client.write_one(point).await?;
    Ok(())
}

// tag values: escape comma, equals, space
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

// string field values: escape double-quote and backslash
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

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    // Regression for the influxdb3 0.2.4 crate bug: it does not escape
    // string field values, so a JSON payload with embedded `"` would
    // produce invalid line protocol and InfluxDB rejects it with
    // "Found trailing content". We escape ourselves; this test pins the
    // exact wire bytes.
    #[test]
    fn payload_field_is_escaped_for_line_protocol() {
        let payload: Value = serde_json::from_str(r#"{"temp":25.0,"hum":79.6}"#).unwrap();

        let dp = DataPointBuilder::new()
            .table(MEASUREMENT)
            .tag(NODE_TAG, &escape_tag("min"))
            .tag(TOPIC_TAG, &escape_tag("mini_c3/sensor"))
            .field(
                PAYLOAD_FIELD,
                FieldDataType::String(escape_field(&payload.to_string())),
            )
            .datetime(Utc::now())
            .build()
            .unwrap();

        let lp = dp.to_line_protocol();
        // inner quotes must be backslash-escaped, otherwise InfluxDB closes
        // the string field early and reports trailing content. field order is
        // unspecified (crate uses HashMap), so check each key independently.
        assert!(lp.contains(r#"\"temp\":25.0"#), "temp not escaped in: {lp}");
        assert!(lp.contains(r#"\"hum\":79.6"#), "hum not escaped in: {lp}");
        // unescaped form (`temp":` without the leading backslash) must NOT appear
        assert!(!lp.contains("temp\":"), "unescaped quote leaked in: {lp}");
    }
}
