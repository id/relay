//! Relay Reference Client
//!
//! A minimal implementation of the Relay protocol (MLS over MQTT).
//! Designed for clarity and ease of translation to other languages.

use std::collections::HashMap;
use std::io::{self, BufRead, Write};
use std::time::Duration;

use anyhow::{anyhow, Result};
use chrono::Local;
use rand::Rng;
use rumqttc::{Client, Event, MqttOptions, Packet, QoS};
use tls_codec::{Deserialize as TlsDeserialize, Serialize as TlsSerialize};

use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;

// ============================================================================
// Logging
// ============================================================================

fn log(msg: &str) {
    let ts = Local::now().format("%H:%M:%S");
    println!("\r[{}] {}", ts, msg);
}

fn log_msg(sender: &str, text: &str, is_self: bool) {
    let ts = Local::now().format("%H:%M:%S");
    let color = if is_self { "34" } else { "32" }; // blue for self, green for peer
    let name = if is_self { "you" } else { sender };
    println!("\r[{}] \x1b[{}m<{}>\x1b[0m {}", ts, color, name, text);
}

// ============================================================================
// Configuration
// ============================================================================

const BROKER_HOST: &str = "broker.emqx.io";
const BROKER_PORT: u16 = 1883;
const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

// ============================================================================
// Application State
// ============================================================================

struct RelayClient {
    // MLS
    backend: OpenMlsRustCrypto,
    client_id: String,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,

    // MQTT
    mqtt: Client,

    // State
    key_packages: HashMap<String, KeyPackage>, // peer_id -> KeyPackage
    groups: HashMap<String, MlsGroup>,         // peer_id -> MlsGroup
    group_peers: HashMap<String, String>,      // group_id (hex) -> peer_id
    pending_connects: Vec<String>,             // peer_ids waiting for KeyPackage
}

// ============================================================================
// Initialization
// ============================================================================

impl RelayClient {
    fn new() -> Result<(Self, rumqttc::Connection)> {
        let backend = OpenMlsRustCrypto::default();

        // Generate client identity
        let client_id = hex::encode(rand::thread_rng().gen::<[u8; 16]>());
        let credential = BasicCredential::new(client_id.clone().into_bytes());
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
            .map_err(|e| anyhow!("KeyGen error: {:?}", e))?;
        signer
            .store(backend.storage())
            .map_err(|e| anyhow!("Storage error: {:?}", e))?;

        let credential = CredentialWithKey {
            credential: credential.into(),
            signature_key: signer.public().into(),
        };

        // Connect to MQTT broker
        let mut options = MqttOptions::new(&client_id, BROKER_HOST, BROKER_PORT);
        options.set_keep_alive(Duration::from_secs(60));
        let (mqtt, connection) = Client::new(options, 100);

        Ok((
            Self {
                backend,
                client_id,
                signer,
                credential,
                mqtt,
                key_packages: HashMap::new(),
                groups: HashMap::new(),
                group_peers: HashMap::new(),
                pending_connects: Vec::new(),
            },
            connection,
        ))
    }

    fn publish_key_package(&self) -> Result<()> {
        let key_package = KeyPackage::builder()
            .build(
                CIPHERSUITE,
                &self.backend,
                &self.signer,
                self.credential.clone(),
            )?
            .key_package()
            .clone();

        // Serialize as MLSMessage, wrap in CBOR array per protocol spec
        let kp_bytes = MlsMessageOut::from(key_package).tls_serialize_detached()?;
        let mut cbor = Vec::new();
        ciborium::into_writer(&vec![kp_bytes], &mut cbor)?;

        self.mqtt.publish(
            format!("relay/k/{}", self.client_id),
            QoS::AtLeastOnce,
            true, // retained
            cbor,
        )?;
        Ok(())
    }

    fn subscribe_welcome(&self) -> Result<()> {
        self.mqtt
            .subscribe(format!("relay/w/{}", self.client_id), QoS::AtLeastOnce)?;
        Ok(())
    }
}

// ============================================================================
// MQTT Message Handlers
// ============================================================================

impl RelayClient {
    fn handle_key_package(&mut self, topic: &str, payload: &[u8]) -> Result<()> {
        // Parse peer_id from topic: relay/k/{peer_id}
        let peer_id = topic
            .strip_prefix("relay/k/")
            .ok_or_else(|| anyhow!("Invalid topic"))?;

        if peer_id == self.client_id {
            return Ok(()); // Ignore our own KeyPackage
        }

        // Decode CBOR array of KeyPackages
        let kp_array: Vec<Vec<u8>> = ciborium::from_reader(payload)?;
        let kp_bytes = kp_array.first().ok_or_else(|| anyhow!("Empty array"))?;

        // Deserialize and validate KeyPackage
        let msg = MlsMessageIn::tls_deserialize(&mut kp_bytes.as_slice())?;
        let kp = match msg.extract() {
            MlsMessageBodyIn::KeyPackage(kp) => {
                kp.validate(self.backend.crypto(), ProtocolVersion::Mls10)?
            }
            _ => return Err(anyhow!("Expected KeyPackage")),
        };

        self.key_packages.insert(peer_id.to_string(), kp);

        // If this peer had a pending connect, establish session now
        if let Some(pos) = self.pending_connects.iter().position(|p| p == peer_id) {
            self.pending_connects.remove(pos);
            self.create_group(peer_id)?;
            log(&format!("Session established with {}", peer_id));
        } else {
            log(&format!("Received KeyPackage for {}", peer_id));
        }
        Ok(())
    }

    fn handle_welcome(&mut self, payload: &[u8]) -> Result<()> {
        // Deserialize Welcome
        let msg = MlsMessageIn::tls_deserialize(&mut payload.to_vec().as_slice())?;
        let welcome = match msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => return Err(anyhow!("Expected Welcome")),
        };

        // Join group
        let config = MlsGroupJoinConfig::builder().build();
        let group = StagedWelcome::new_from_welcome(&self.backend, &config, welcome, None)?
            .into_group(&self.backend)?;

        let group_id = hex::encode(group.group_id().as_slice());

        // Find peer (the other member)
        let peer_id = group
            .members()
            .find_map(|m| {
                let id = String::from_utf8(m.credential.serialized_content().to_vec()).ok()?;
                if id != self.client_id {
                    Some(id)
                } else {
                    None
                }
            })
            .unwrap_or_else(|| "unknown".to_string());

        // Subscribe to group messages
        self.mqtt
            .subscribe(format!("relay/g/{}/m", group_id), QoS::AtLeastOnce)?;

        self.group_peers.insert(group_id, peer_id.clone());
        self.groups.insert(peer_id.clone(), group);

        // Publish a fresh KeyPackage (our old one was consumed)
        self.publish_key_package()?;

        log(&format!("Session established with {}", peer_id));
        log(&format!("Use 'chat {} <message>' to reply", peer_id));
        Ok(())
    }

    fn handle_group_message(&mut self, topic: &str, payload: &[u8]) -> Result<()> {
        // Parse group_id from topic: relay/g/{group_id}/m
        let group_id = topic
            .strip_prefix("relay/g/")
            .and_then(|s| s.strip_suffix("/m"))
            .ok_or_else(|| anyhow!("Invalid topic"))?;

        let peer_id = self
            .group_peers
            .get(group_id)
            .ok_or_else(|| anyhow!("Unknown group"))?
            .clone();

        let group = self
            .groups
            .get_mut(&peer_id)
            .ok_or_else(|| anyhow!("No group"))?;

        // Deserialize MLS message
        let msg = MlsMessageIn::tls_deserialize(&mut payload.to_vec().as_slice())?;
        let protocol_msg = match msg.extract() {
            MlsMessageBodyIn::PrivateMessage(m) => ProtocolMessage::from(m),
            MlsMessageBodyIn::PublicMessage(m) => ProtocolMessage::from(m),
            _ => return Err(anyhow!("Expected PrivateMessage or PublicMessage")),
        };

        // Process message
        let processed = match group.process_message(&self.backend, protocol_msg) {
            Ok(p) => p,
            Err(ProcessMessageError::ValidationError(ValidationError::CannotDecryptOwnMessage)) => {
                return Ok(())
            } // Skip own messages
            Err(e) => return Err(anyhow!("MLS error: {:?}", e)),
        };

        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app_msg) => {
                let bytes = app_msg.into_bytes();
                let text = String::from_utf8_lossy(&bytes);
                log_msg(&peer_id, &text, false);
            }
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                group.merge_staged_commit(&self.backend, *staged)?;
            }
            _ => {}
        }
        Ok(())
    }
}

// ============================================================================
// Commands
// ============================================================================

impl RelayClient {
    fn connect(&mut self, peer_id: &str) -> Result<()> {
        if self.groups.contains_key(peer_id) {
            log(&format!("Already connected to {}", peer_id));
            return Ok(());
        }

        // If we already have their KeyPackage, establish session immediately
        if self.key_packages.contains_key(peer_id) {
            self.create_group(peer_id)?;
            log(&format!("Session established with {}", peer_id));
            return Ok(());
        }

        // Otherwise, fetch KeyPackage and mark as pending
        self.pending_connects.push(peer_id.to_string());
        self.mqtt
            .subscribe(format!("relay/k/{}", peer_id), QoS::AtLeastOnce)?;
        log(&format!("Connecting to {}...", peer_id));
        Ok(())
    }

    fn send(&mut self, peer_id: &str, text: &str) -> Result<()> {
        // Try to find group by peer_id or partial match
        let peer = self.find_peer(peer_id)?;

        // Must have an active session
        if !self.groups.contains_key(&peer) {
            return Err(anyhow!(
                "No session with {}. Use 'connect {}' first.",
                peer,
                peer
            ));
        }

        let group = self.groups.get_mut(&peer).unwrap();
        let group_id = hex::encode(group.group_id().as_slice());

        // Create and send message
        let mls_msg = group.create_message(&self.backend, &self.signer, text.as_bytes())?;
        let msg_bytes = mls_msg.tls_serialize_detached()?;

        self.mqtt.publish(
            format!("relay/g/{}/m", group_id),
            QoS::AtLeastOnce,
            false,
            msg_bytes,
        )?;

        // Show sent message locally
        log_msg("", text, true);
        Ok(())
    }

    fn find_peer(&self, query: &str) -> Result<String> {
        // Exact match in groups
        if self.groups.contains_key(query) {
            return Ok(query.to_string());
        }

        // Exact match in key_packages
        if self.key_packages.contains_key(query) {
            return Ok(query.to_string());
        }

        // Partial match in groups (prefix)
        let group_matches: Vec<_> = self
            .groups
            .keys()
            .filter(|k| k.starts_with(query))
            .collect();
        if group_matches.len() == 1 {
            return Ok(group_matches[0].clone());
        }

        // Partial match in key_packages (prefix)
        let kp_matches: Vec<_> = self
            .key_packages
            .keys()
            .filter(|k| k.starts_with(query))
            .collect();
        if kp_matches.len() == 1 {
            return Ok(kp_matches[0].clone());
        }

        // Show available peers
        let mut available = vec![];
        for peer in self.groups.keys() {
            available.push(format!("{} (session)", peer));
        }
        for peer in self.key_packages.keys() {
            if !self.groups.contains_key(peer) {
                available.push(format!("{} (keypackage)", peer));
            }
        }

        if available.is_empty() {
            Err(anyhow!(
                "No peers available. Use 'connect <peer_id>' first."
            ))
        } else {
            Err(anyhow!(
                "Unknown peer '{}'. Available:\n  {}",
                query,
                available.join("\n  ")
            ))
        }
    }

    fn create_group(&mut self, peer_id: &str) -> Result<()> {
        let peer_kp = self
            .key_packages
            .get(peer_id)
            .ok_or_else(|| anyhow!("No KeyPackage for peer (use 'connect' first)"))?
            .clone();

        // Generate random group_id
        let group_id_bytes: [u8; 16] = rand::thread_rng().gen();
        let group_id = hex::encode(group_id_bytes);

        // Create group
        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .use_ratchet_tree_extension(true)
            .build();

        let mut group = MlsGroup::new_with_group_id(
            &self.backend,
            &self.signer,
            &config,
            GroupId::from_slice(&group_id_bytes),
            self.credential.clone(),
        )?;

        // Add peer
        let (_, welcome, group_info) =
            group.add_members(&self.backend, &self.signer, &[peer_kp])?;
        group.merge_pending_commit(&self.backend)?;

        // Publish GroupInfo (retained)
        self.mqtt.publish(
            format!("relay/g/{}/i", group_id),
            QoS::AtLeastOnce,
            true,
            group_info.tls_serialize_detached()?,
        )?;

        // Send Welcome
        self.mqtt.publish(
            format!("relay/w/{}", peer_id),
            QoS::AtLeastOnce,
            false,
            welcome.tls_serialize_detached()?,
        )?;

        // Subscribe to group messages
        self.mqtt
            .subscribe(format!("relay/g/{}/m", group_id), QoS::AtLeastOnce)?;

        self.group_peers.insert(group_id, peer_id.to_string());
        self.groups.insert(peer_id.to_string(), group);

        Ok(())
    }
}

// ============================================================================
// Main Loop
// ============================================================================

fn main() -> Result<()> {
    let (mut client, mut connection) = RelayClient::new()?;

    println!("Client ID: {}", client.client_id);

    client.publish_key_package()?;
    client.subscribe_welcome()?;

    // Channel for MQTT events
    let (tx, rx) = std::sync::mpsc::channel();

    // Spawn MQTT event loop in background thread
    std::thread::spawn(move || {
        for event in connection.iter() {
            if let Ok(Event::Incoming(Packet::Publish(p))) = event {
                let _ = tx.send((p.topic.clone(), p.payload.to_vec()));
            }
        }
    });

    // Channel for stdin lines
    let (stdin_tx, stdin_rx) = std::sync::mpsc::channel();

    // Spawn stdin reader in background thread
    std::thread::spawn(move || {
        let stdin = io::stdin();
        for line in stdin.lock().lines().map_while(Result::ok) {
            let _ = stdin_tx.send(line);
        }
    });

    print!("> ");
    io::stdout().flush()?;

    loop {
        // Check for MQTT messages (non-blocking)
        while let Ok((topic, payload)) = rx.try_recv() {
            let result = if topic.starts_with("relay/k/") {
                client.handle_key_package(&topic, &payload)
            } else if topic.starts_with("relay/w/") {
                client.handle_welcome(&payload)
            } else if topic.starts_with("relay/g/") && topic.ends_with("/m") {
                client.handle_group_message(&topic, &payload)
            } else {
                Ok(())
            };

            if let Err(e) = result {
                eprintln!("\rError: {:?}", e);
            }
            print!("> ");
            io::stdout().flush()?;
        }

        // Check for stdin input (non-blocking)
        if let Ok(line) = stdin_rx.try_recv() {
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.is_empty() {
                print!("> ");
                io::stdout().flush()?;
                continue;
            }

            let result = match parts[0] {
                "info" => {
                    println!("Client ID: {}", client.client_id);
                    Ok(())
                }
                "peers" => {
                    if client.groups.is_empty() && client.key_packages.is_empty() {
                        println!("No peers. Use 'connect <peer_id>' to connect.");
                    } else {
                        println!("Active sessions:");
                        for peer in client.groups.keys() {
                            println!("  {} (session)", peer);
                        }
                        for peer in client.key_packages.keys() {
                            if !client.groups.contains_key(peer) {
                                println!("  {} (keypackage only)", peer);
                            }
                        }
                    }
                    Ok(())
                }
                "connect" if parts.len() >= 2 => client.connect(parts[1]),
                "chat" if parts.len() >= 3 => client.send(parts[1], &parts[2..].join(" ")),
                "quit" | "exit" => break,
                _ => {
                    println!("Commands: info, peers, connect <peer>, chat <peer> <msg>, quit");
                    Ok(())
                }
            };

            if let Err(e) = result {
                println!("Error: {:?}", e);
            }
            print!("> ");
            io::stdout().flush()?;
        }

        // Small sleep to avoid busy-waiting
        std::thread::sleep(Duration::from_millis(10));
    }

    Ok(())
}
