use rumqttc::{Client, Event, MqttOptions, Packet, QoS};
use std::time::Duration;
use tokio::sync::mpsc;

use crate::db::Reading;

const MQTT_PORT: u16 = 1883;
const KEEP_ALIVE_SECS: u64 = 5;
const QUEUE_CAP: usize = 10;
const CHANNEL_CAP: usize = 256;
const NODE_UNKNOWN: &str = "unknown";

pub fn listener_mac() -> String {
    mac_address::get_mac_address()
        .ok()
        .flatten()
        .map(|m| m.to_string().replace(':', ""))
        .unwrap_or_else(|| NODE_UNKNOWN.to_string())
}

pub struct MqttHandle {
    pub rx: mpsc::Receiver<Reading>,
}

pub fn run(host: String, topic: String, listener_id: String) -> MqttHandle {
    let (tx, rx) = mpsc::channel(CHANNEL_CAP);

    std::thread::spawn(move || {
        let mut options = MqttOptions::new(format!("listen_{listener_id}"), host, MQTT_PORT);
        options.set_keep_alive(Duration::from_secs(KEEP_ALIVE_SECS));

        let (client, mut connection) = Client::new(options, QUEUE_CAP);
        client.subscribe(&topic, QoS::AtLeastOnce).unwrap();

        println!("listen_{listener_id} on {topic}");

        for event in connection.iter() {
            let Ok(Event::Incoming(Packet::Publish(publish))) = event else {
                continue;
            };

            let node_id = extract_node_id(&publish.topic);
            let payload = parse_payload(&publish.payload);

            let reading = Reading {
                node_id,
                topic: publish.topic.clone(),
                payload,
            };

            if tx.blocking_send(reading).is_err() {
                break;
            }
        }
    });

    MqttHandle { rx }
}

fn extract_node_id(topic: &str) -> String {
    topic
        .split('/')
        .find(|seg| !seg.is_empty())
        .unwrap_or(NODE_UNKNOWN)
        .to_string()
}

fn parse_payload(bytes: &[u8]) -> serde_json::Value {
    serde_json::from_slice(bytes).unwrap_or_else(|_| {
        let s = String::from_utf8_lossy(bytes).to_string();
        serde_json::Value::String(s)
    })
}
