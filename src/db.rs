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
    let point = DataPointBuilder::new()
        .table(MEASUREMENT)
        .tag(NODE_TAG, &r.node_id)
        .tag(TOPIC_TAG, &r.topic)
        .field(PAYLOAD_FIELD, FieldDataType::String(r.payload.to_string()))
        .datetime(Utc::now())
        .build()?;

    influx.client.write_one(point).await?;
    Ok(())
}
