use std::time::Duration;

use chrono::Utc;
use influxdb3::data_point::DataPoint;
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
const TEMP_FIELD: &str = "temp";
const HUM_FIELD: &str = "hum";

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

// Pure point construction, split out so it can be unit-tested without HTTP.
// influxdb3 0.2.4's DataPointBuilder does NOT escape tag values or string
// field values (see its `TODO` in data_point.rs), so we escape per the
// line-protocol spec ourselves. If the crate ever implements escaping, these
// helpers become a double-escape — revisit on upgrade.
fn build_point(r: &Reading) -> Result<DataPoint, influxdb3::Error> {
    let mut builder = DataPointBuilder::new();
    builder
        .table(MEASUREMENT)
        .tag(NODE_TAG, &escape_tag(&r.node_id))
        .tag(TOPIC_TAG, &escape_tag(&r.topic))
        .field(
            PAYLOAD_FIELD,
            FieldDataType::String(escape_field(&r.payload.to_string())),
        );

    // Flatten known numeric fields so Grafana can aggregate them. `payload`
    // above stays as raw capture but is a string InfluxDB can't chart. Skip a
    // field when the JSON doesn't carry it — writing a fake 0.0 would skew
    // mean()/sum() in Grafana.
    if let Some(temp) = r.payload.get(TEMP_FIELD).and_then(Value::as_f64) {
        builder.field(TEMP_FIELD, FieldDataType::Float(temp));
    }
    if let Some(hum) = r.payload.get(HUM_FIELD).and_then(Value::as_f64) {
        builder.field(HUM_FIELD, FieldDataType::Float(hum));
    }

    builder.datetime(Utc::now()).build()
}

pub async fn insert_reading(influx: &Influx, r: &Reading) -> Result<(), influxdb3::Error> {
    let point = build_point(r)?;
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

    // Covers two things at once: (1) the influxdb3 0.2.4 crate bug where string
    // field values aren't escaped (would make InfluxDB reject the line with
    // "Found trailing content"), and (2) temp/hum are real numeric fields so
    // Grafana can aggregate them. Field order is unspecified (crate uses a
    // HashMap) so each key is checked independently.
    #[test]
    fn point_has_numeric_temp_hum_and_escaped_payload() {
        let r = Reading {
            node_id: "min".to_string(),
            topic: "mini_c3/sensor".to_string(),
            payload: serde_json::from_str(r#"{"temp":25.0,"hum":79.6}"#).unwrap(),
        };

        let lp = build_point(&r).unwrap().to_line_protocol();

        // numeric (unquoted) — Grafana can mean()/sum() them
        assert!(lp.contains("temp=25"), "temp not numeric in: {lp}");
        assert!(lp.contains("hum=79.6"), "hum not numeric in: {lp}");
        assert!(
            !lp.contains("temp=\""),
            "temp wrongly string-typed in: {lp}"
        );
        assert!(!lp.contains("hum=\""), "hum wrongly string-typed in: {lp}");
        // payload string still present, inner quotes backslash-escaped
        assert!(lp.contains(r#"\"temp\""#), "payload not escaped in: {lp}");
        assert!(!lp.contains("temp\":"), "unescaped quote leaked in: {lp}");
    }
}
