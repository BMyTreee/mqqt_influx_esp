mod db;
mod mqtt;

use db::insert_reading;
use mqtt::listener_mac;
use tracing::{info, warn};

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
    let topic = std::env::var("MQTT_TOPIC").expect("MQTT_TOPIC not set");
    let listener_id = listener_mac();
    info!(listener_id = %listener_id, host = %host, topic = %topic, "starting listener");

    let influx = db::connect().await?;

    let mut handle = mqtt::run(host, topic, listener_id);

    while let Some(reading) = handle.rx.recv().await {
        match insert_reading(&influx, &reading).await {
            Ok(_) => info!(node_id = %reading.node_id, topic = %reading.topic, "stored reading"),
            Err(e) => warn!(topic = %reading.topic, error = %e, "insert failed"),
        }
    }

    warn!("mqtt stream closed");
    Ok(())
}
