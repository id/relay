use std::collections::HashMap;
use std::io::{self, BufRead, Write};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use aes_gcm::aead::{generic_array::GenericArray, Aead};
use aes_gcm::{AeadCore, Aes256Gcm, KeyInit};
use anyhow::{anyhow, Result};
use curve25519_dalek::montgomery::MontgomeryPoint;
use curve25519_dalek::scalar::Scalar;
use hkdf::Hkdf;
use rand::Rng;
use rumqttc::{AsyncClient, Event, MqttOptions, Packet, QoS};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::task;

use ::tls_codec::{Deserialize as TlsDeserialize, Serialize as TlsSerialize};
use openmls::credentials::CredentialWithKey;
use openmls::group::{MlsGroupCreateConfig, MlsGroupJoinConfig, StagedWelcome};
use openmls::key_packages::KeyPackage;
use openmls::prelude::*;
use openmls::treesync::RatchetTreeIn;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use openmls_traits::OpenMlsProvider;

const BROKER_HOST: &str = "broker.emqx.io";
const BROKER_PORT: u16 = 1883;
const TOPIC_PREFIX: &str = "relay";

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SealedEnvelope {
    version: u8,
    #[serde(with = "serde_bytes")]
    ephemeral_public_key: Vec<u8>,
    #[serde(with = "serde_bytes")]
    encrypted_payload: Vec<u8>,
    pow_nonce: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct InnerPayload {
    msg_type: u8,
    sender_user_id: String,
    #[serde(with = "serde_bytes")]
    sender_identity_key: Vec<u8>,
    #[serde(with = "serde_bytes")]
    content: Vec<u8>,
    // Optional: Include ratchet tree or other out-of-band info
    #[serde(with = "serde_bytes")]
    ratchet_tree: Vec<u8>,
    // Sender's outer public key for sealed sender
    #[serde(with = "serde_bytes")]
    sender_outer_public_key: Vec<u8>,
}

#[derive(Serialize, Deserialize)]
struct PublicBundle {
    key_package: Vec<u8>,
    #[serde(with = "serde_bytes")]
    sealed_sender_public_key: Vec<u8>,
}

#[derive(Serialize, Deserialize)]
struct ChatMessage {
    content: String,
}

struct AppState {
    backend: Arc<OpenMlsRustCrypto>,
    user_id: String,
    signer: Arc<SignatureKeyPair>,
    credential_with_key: CredentialWithKey,
    key_package: KeyPackage,
    outer_secret: Scalar,
    #[allow(dead_code)]
    outer_public: MontgomeryPoint,
    peer_bundles: HashMap<String, PublicBundle>,
    peer_outer_keys: HashMap<String, Vec<u8>>, // Just the outer public keys
    groups: HashMap<String, MlsGroup>,
}

fn generate_outer_keys() -> (Scalar, MontgomeryPoint) {
    let mut rng = rand::thread_rng();
    let secret = Scalar::random(&mut rng);
    let public = MontgomeryPoint::mul_base(&secret);
    (secret, public)
}

fn seal_message(payload: &InnerPayload, peer_public_bytes: &[u8]) -> Result<SealedEnvelope> {
    let mut payload_bytes = Vec::new();
    ciborium::into_writer(payload, &mut payload_bytes)?;

    let (eph_sec, eph_pub) = generate_outer_keys();
    let peer_point = MontgomeryPoint(
        peer_public_bytes
            .try_into()
            .map_err(|_| anyhow!("Invalid Key"))?,
    );
    let shared_secret = eph_sec * peer_point;

    let hkdf = Hkdf::<Sha256>::new(None, shared_secret.as_bytes());
    let mut key_bytes = [0u8; 32];
    hkdf.expand(b"relay-seal-v1", &mut key_bytes).unwrap();

    let cipher = Aes256Gcm::new(GenericArray::from_slice(&key_bytes));
    let nonce = Aes256Gcm::generate_nonce(&mut rand::thread_rng());
    let ciphertext = cipher
        .encrypt(&nonce, payload_bytes.as_ref())
        .map_err(|_| anyhow!("Encrypt Fail"))?;

    let mut final_ct = nonce.to_vec();
    final_ct.extend(ciphertext);

    let mut envelope = SealedEnvelope {
        version: 1,
        ephemeral_public_key: eph_pub.as_bytes().to_vec(),
        encrypted_payload: final_ct,
        pow_nonce: 0,
    };

    print!("Mining PoW...");
    io::stdout().flush()?;
    loop {
        let mut hasher = Sha256::new();
        let mut bytes = Vec::new();
        ciborium::into_writer(&envelope, &mut bytes)?;
        hasher.update(&bytes);
        let hash = hasher.finalize();
        if hash[0] == 0 && hash[1] == 0 {
            println!(" Done!");
            break;
        }
        envelope.pow_nonce += 1;
    }
    Ok(envelope)
}

fn unseal_message(envelope: &SealedEnvelope, my_secret: Scalar) -> Result<InnerPayload> {
    let mut hasher = Sha256::new();
    let mut bytes = Vec::new();
    ciborium::into_writer(envelope, &mut bytes)?;
    hasher.update(&bytes);
    let hash = hasher.finalize();
    if hash[0] != 0 || hash[1] != 0 {
        return Err(anyhow!("Invalid PoW"));
    }

    let eph_point = MontgomeryPoint(
        envelope
            .ephemeral_public_key
            .clone()
            .try_into()
            .map_err(|_| anyhow!("Key"))?,
    );
    let shared = my_secret * eph_point;

    let hkdf = Hkdf::<Sha256>::new(None, shared.as_bytes());
    let mut key_bytes = [0u8; 32];
    hkdf.expand(b"relay-seal-v1", &mut key_bytes).unwrap();

    let cipher = Aes256Gcm::new(GenericArray::from_slice(&key_bytes));
    if envelope.encrypted_payload.len() < 12 {
        return Err(anyhow!("Short"));
    }
    let (nonce, ct) = envelope.encrypted_payload.split_at(12);

    let plain = cipher
        .decrypt(GenericArray::from_slice(nonce), ct)
        .map_err(|_| anyhow!("Decrypt Fail"))?;
    Ok(ciborium::from_reader(plain.as_slice())?)
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();
    let backend = OpenMlsRustCrypto::default();

    let user_id = hex::encode(rand::thread_rng().gen::<[u8; 16]>());
    println!(">>> My User ID: {}", user_id);

    let ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

    let credential = BasicCredential::new(user_id.clone().into_bytes());
    let signature_keys = SignatureKeyPair::new(ciphersuite.signature_algorithm())
        .map_err(|e| anyhow!("KeyGen Error: {:?}", e))?;

    signature_keys
        .store(backend.storage())
        .map_err(|e| anyhow!("Storage Error: {:?}", e))?;

    let credential_with_key = CredentialWithKey {
        credential: credential.into(),
        signature_key: signature_keys.public().into(),
    };

    let key_package_bundle = KeyPackage::builder().build(
        ciphersuite,
        &backend,
        &signature_keys,
        credential_with_key.clone(),
    )?;

    let key_package = key_package_bundle.key_package().clone();

    let (outer_secret, outer_public) = generate_outer_keys();

    let state = Arc::new(Mutex::new(AppState {
        backend: Arc::new(backend),
        user_id: user_id.clone(),
        signer: Arc::new(signature_keys),
        credential_with_key,
        key_package: key_package.clone(),
        outer_secret,
        outer_public,
        peer_bundles: HashMap::new(),
        peer_outer_keys: HashMap::new(),
        groups: HashMap::new(),
    }));

    let mut mqttoptions = MqttOptions::new(&user_id, BROKER_HOST, BROKER_PORT);
    mqttoptions.set_keep_alive(Duration::from_secs(60));
    let (client, mut eventloop) = AsyncClient::new(mqttoptions, 10);

    let kp_msg_out = MlsMessageOut::from(state.lock().unwrap().key_package.clone());
    let bundle = PublicBundle {
        key_package: kp_msg_out.tls_serialize_detached()?,
        sealed_sender_public_key: outer_public.as_bytes().to_vec(),
    };
    client
        .publish(
            format!("{}/u/{}/keys", TOPIC_PREFIX, user_id),
            QoS::AtLeastOnce,
            true,
            serde_json::to_vec(&bundle)?,
        )
        .await?;
    client
        .subscribe(
            format!("{}/u/{}/inbox", TOPIC_PREFIX, user_id),
            QoS::AtLeastOnce,
        )
        .await?;

    let state_clone = state.clone();

    task::spawn(async move {
        while let Ok(event) = eventloop.poll().await {
            if let Event::Incoming(Packet::Publish(p)) = event {
                let topic = p.topic.clone();
                if topic.ends_with("/inbox") {
                    match process_inbox(&p.payload, &state_clone) {
                        Ok((sender, msg)) => {
                            println!("\r\x1b[32m<{}>\x1b[0m {}", sender, msg);
                            print!("> ");
                            io::stdout().flush().unwrap();
                        }
                        Err(e) => eprintln!("Error processing inbox: {:?}", e),
                    }
                } else if topic.ends_with("/keys") {
                    if let Ok(bundle) = serde_json::from_slice::<PublicBundle>(&p.payload) {
                        let parts: Vec<&str> = topic.split('/').collect();
                        if parts.len() >= 3 {
                            let peer_id = parts[2].to_string();
                            state_clone
                                .lock()
                                .unwrap()
                                .peer_bundles
                                .insert(peer_id.clone(), bundle);
                            println!("\r[System] Received keys for {}. Ready to chat.", peer_id);
                            print!("> ");
                            io::stdout().flush().unwrap();
                        }
                    }
                }
            }
        }
    });

    let stdin = io::stdin();
    print!("> ");
    io::stdout().flush()?;
    for line in stdin.lock().lines() {
        let line = line?;
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.is_empty() {
            continue;
        }

        match parts[0] {
            "info" => println!("ID: {}", user_id),
            "connect" => {
                if parts.len() < 2 {
                    println!("Usage: connect <peer_id>");
                    continue;
                }
                let peer = parts[1];
                client
                    .subscribe(
                        format!("{}/u/{}/keys", TOPIC_PREFIX, peer),
                        QoS::AtLeastOnce,
                    )
                    .await?;
                println!("Fetching keys...");
            }
            "chat" => {
                if parts.len() < 3 {
                    println!("Usage: chat <peer_id> <msg>");
                    continue;
                }
                let peer = parts[1];
                let msg = parts[2..].join(" ");
                if let Err(e) = send_chat(&client, &state, peer, &msg).await {
                    println!("Error sending: {:?}", e);
                }
            }
            _ => println!("cmds: info, connect, chat"),
        }
        print!("> ");
        io::stdout().flush()?;
    }
    Ok(())
}

fn process_inbox(payload: &[u8], state: &Arc<Mutex<AppState>>) -> Result<(String, String)> {
    let (my_secret, backend) = {
        let g = state.lock().unwrap();
        (g.outer_secret, g.backend.clone())
    };

    let envelope: SealedEnvelope = ciborium::from_reader(payload)?;
    let inner = unseal_message(&envelope, my_secret)?;

    let mut g = state.lock().unwrap();

    // Store sender's outer public key for future replies
    if !inner.sender_outer_public_key.is_empty() {
        g.peer_outer_keys.insert(
            inner.sender_user_id.clone(),
            inner.sender_outer_public_key.clone(),
        );
    }

    if inner.msg_type == 3 {
        // Welcome message
        let serialized_welcome = inner.content;

        let mls_message_in = MlsMessageIn::tls_deserialize(&mut serialized_welcome.as_slice())?;

        let welcome = match mls_message_in.extract() {
            MlsMessageBodyIn::Welcome(welcome) => welcome,
            _ => return Err(anyhow!("Expected Welcome message")),
        };

        let group_config = MlsGroupJoinConfig::builder().build();

        // Deserialize ratchet tree if present
        let ratchet_tree_option = if inner.ratchet_tree.is_empty() {
            None
        } else {
            let rt: RatchetTreeIn =
                TlsDeserialize::tls_deserialize(&mut inner.ratchet_tree.as_slice())?;
            Some(rt)
        };

        let staged_welcome = StagedWelcome::new_from_welcome(
            &*backend,
            &group_config,
            welcome,
            ratchet_tree_option,
        )?;

        let group = staged_welcome.into_group(&*backend)?;

        g.groups.insert(inner.sender_user_id.clone(), group);
        Ok((inner.sender_user_id, "--- Session Established ---".into()))
    } else if inner.msg_type == 5 {
        // Application message
        let group = g
            .groups
            .get_mut(&inner.sender_user_id)
            .ok_or(anyhow!("No Group"))?;

        let msg_in: MlsMessageIn = TlsDeserialize::tls_deserialize(&mut inner.content.as_slice())?;

        let protocol_msg = match msg_in.extract() {
            MlsMessageBodyIn::PrivateMessage(pm) => ProtocolMessage::from(pm),
            MlsMessageBodyIn::PublicMessage(pm) => ProtocolMessage::from(pm),
            _ => return Err(anyhow!("Unexpected message type in inbox")),
        };

        let processed = group.process_message(&*backend, protocol_msg)?;

        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app_msg) => {
                let bytes = app_msg.into_bytes();
                let cm: ChatMessage = serde_json::from_slice(&bytes)?;
                Ok((inner.sender_user_id, cm.content))
            }
            ProcessedMessageContent::ProposalMessage(_) => {
                Ok((inner.sender_user_id, "[Proposal]".into()))
            }
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                group.merge_staged_commit(&*backend, *staged)?;
                Ok((inner.sender_user_id, "[Commit Merged]".into()))
            }
            _ => Ok((inner.sender_user_id, "[Unhandled Message]".into())),
        }
    } else {
        Err(anyhow!("Unknown Type"))
    }
}

async fn send_chat(
    client: &AsyncClient,
    state: &Arc<Mutex<AppState>>,
    peer: &str,
    text: &str,
) -> Result<()> {
    let (payload, _peer_key) = {
        // Scope for lock
        let mut g = state.lock().unwrap();

        // Clone Arcs to share access
        let backend = g.backend.clone();
        let signer = g.signer.clone();
        let credential_with_key = g.credential_with_key.clone();
        let user_id = g.user_id.clone();

        let has_group = g.groups.contains_key(peer);

        if !has_group {
            let bundle = g
                .peer_bundles
                .get(peer)
                .ok_or(anyhow!("Unknown peer (run connect)"))?;
            let peer_pk = bundle.sealed_sender_public_key.clone();

            // Deserialize and validate KeyPackage
            let msg_in: MlsMessageIn =
                TlsDeserialize::tls_deserialize(&mut bundle.key_package.as_slice())?;
            let kp_in = match msg_in.extract() {
                MlsMessageBodyIn::KeyPackage(kp) => kp,
                _ => return Err(anyhow!("Expected KeyPackage")),
            };

            let kp = kp_in
                .validate(backend.crypto(), ProtocolVersion::Mls10)
                .map_err(|e| anyhow!("KeyPackage validation failed: {:?}", e))?;

            let group_config = MlsGroupCreateConfig::builder()
                .ciphersuite(Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519)
                .build();

            // Use deref for &impl OpenMlsProvider and &SignatureKeyPair
            let mut group = MlsGroup::new(
                &*backend,
                &*signer,
                &group_config,
                credential_with_key.clone(),
            )?;

            let (_msg_out, welcome, _info) = group.add_members(&*backend, &*signer, &[kp])?;

            // Merge pending commit before exporting ratchet tree
            group.merge_pending_commit(&*backend)?;

            // Export ratchet tree AFTER merging so it matches the Welcome's GroupInfo
            let ratchet_tree = group.export_ratchet_tree();
            let ratchet_tree_bytes = ratchet_tree.tls_serialize_detached()?;

            g.groups.insert(peer.to_string(), group);

            let sender_outer_pk = g.outer_public.as_bytes().to_vec();
            let welcome_inner = InnerPayload {
                msg_type: 3,
                sender_user_id: user_id.clone(),
                sender_identity_key: vec![],
                content: welcome.tls_serialize_detached()?,
                ratchet_tree: ratchet_tree_bytes,
                sender_outer_public_key: sender_outer_pk,
            };
            let welcome_sealed = seal_message(&welcome_inner, &peer_pk)?;
            let mut buf = Vec::new();
            ciborium::into_writer(&welcome_sealed, &mut buf)?;
            client
                .publish(
                    format!("{}/u/{}/inbox", TOPIC_PREFIX, peer),
                    QoS::AtLeastOnce,
                    false,
                    buf,
                )
                .await?;
        }

        let group = g.groups.get_mut(peer).unwrap();
        let cm = ChatMessage {
            content: text.to_string(),
        };
        let mls_msg_out = group.create_message(&*backend, &*signer, &serde_json::to_vec(&cm)?)?;

        let sender_outer_pk = g.outer_public.as_bytes().to_vec();
        let inner = InnerPayload {
            msg_type: 5,
            sender_user_id: user_id,
            sender_identity_key: vec![],
            content: mls_msg_out.tls_serialize_detached()?,
            ratchet_tree: vec![],
            sender_outer_public_key: sender_outer_pk,
        };

        // Get peer's outer public key from bundle or from stored keys
        let peer_pk = g
            .peer_bundles
            .get(peer)
            .map(|b| b.sealed_sender_public_key.clone())
            .or_else(|| g.peer_outer_keys.get(peer).cloned())
            .ok_or(anyhow!("No peer public key available"))?;
        (seal_message(&inner, &peer_pk)?, peer_pk)
    };

    let mut buf = Vec::new();
    ciborium::into_writer(&payload, &mut buf)?;
    client
        .publish(
            format!("{}/u/{}/inbox", TOPIC_PREFIX, peer),
            QoS::AtLeastOnce,
            false,
            buf,
        )
        .await?;
    Ok(())
}
