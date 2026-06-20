mod db;
mod mqtt;

use db::insert_reading;
use mqtt::listener_mac;
use tracing::{info, warn};

const MQTT_PORT_DEFAULT: u16 = 1884;
const MQTT_TOPIC_DEFAULT: &str = "mini_c3/sensor";

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    dotenvy::dotenv().ok();

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let host = std::env::var("MQTT_HOST").expect("MQTT_HOST not set");
    let topic = std::env::var("MQTT_TOPIC").unwrap_or_else(|_| MQTT_TOPIC_DEFAULT.to_string());
    let port: u16 = std::env::var("MQTT_PORT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(MQTT_PORT_DEFAULT);
    let listener_id = listener_mac();
    info!(listener_id = %listener_id, host = %host, port, topic = %topic, "starting listener");

    let influx = db::connect().await?;

    let mut handle = mqtt::run(host, port, topic, listener_id);

    while let Some(reading) = handle.rx.recv().await {
        match insert_reading(&influx, &reading).await {
            Ok(_) => info!(node_id = %reading.node_id, topic = %reading.topic, "stored reading"),
            Err(e) => warn!(topic = %reading.topic, error = %e, "insert failed"),
        }
    }

    warn!("mqtt stream closed");
    Ok(())
}
