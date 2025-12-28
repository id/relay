use openmls::prelude::*;
use openmls_basic_credential::SignatureKeyPair;
use openmls_rust_crypto::OpenMlsRustCrypto;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tls_codec::{Deserialize as TlsDeserializeTrait, Serialize as TlsSerializeTrait};

// ============================================================================
// Error Types
// ============================================================================

#[derive(Debug, thiserror::Error)]
pub enum OpenMlsError {
    #[error("MLS error: {0}")]
    MlsError(String),

    #[error("Serialization error: {0}")]
    SerializationError(String),

    #[error("Invalid input: {0}")]
    InvalidInput(String),

    #[error("Group not found")]
    GroupNotFound,
}

// ============================================================================
// Data Types
// ============================================================================

#[derive(Clone)]
pub struct ClientIdentity {
    pub client_id: String,
    pub credential_bytes: Vec<u8>,
    pub signature_public_key: Vec<u8>,
}

pub struct KeyPackageBundle {
    pub key_package_bytes: Vec<u8>,
    pub key_package_hash: Vec<u8>,
}

pub struct AddMemberResult {
    pub welcome_bytes: Vec<u8>,
    pub commit_bytes: Vec<u8>,
}

pub struct DecryptedMessage {
    pub plaintext: Vec<u8>,
    pub sender_client_id: String,
}

pub struct JoinGroupResult {
    pub group_id: String,
}

const CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_AES128GCM_SHA256_Ed25519;

// ============================================================================
// RelayMlsClient - Stateful client matching relay-rs design
// ============================================================================

pub struct RelayMlsClient {
    backend: OpenMlsRustCrypto,
    client_id: String,
    signer: SignatureKeyPair,
    credential: CredentialWithKey,
    groups: Mutex<HashMap<String, MlsGroup>>, // group_id (hex) -> MlsGroup
}

impl RelayMlsClient {
    pub fn new(client_id: String) -> Result<Self, OpenMlsError> {
        let backend = OpenMlsRustCrypto::default();

        // Create credential from client_id
        let credential = BasicCredential::new(client_id.clone().into_bytes());

        // Generate signature keypair (persisted for lifetime of client)
        let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
            .map_err(|e| OpenMlsError::MlsError(format!("Failed to create signer: {:?}", e)))?;

        // Store signer in backend
        signer
            .store(backend.storage())
            .map_err(|e| OpenMlsError::MlsError(format!("Failed to store signer: {:?}", e)))?;

        let credential_with_key = CredentialWithKey {
            credential: credential.into(),
            signature_key: signer.public().into(),
        };

        Ok(Self {
            backend,
            client_id,
            signer,
            credential: credential_with_key,
            groups: Mutex::new(HashMap::new()),
        })
    }

    pub fn client_id(&self) -> String {
        self.client_id.clone()
    }

    /// Create a KeyPackage in CBOR-wrapped MLSMessage format per Relay protocol
    pub fn create_key_package(&self) -> Result<Vec<u8>, OpenMlsError> {
        let key_package = KeyPackage::builder()
            .build(
                CIPHERSUITE,
                &self.backend,
                &self.signer,
                self.credential.clone(),
            )
            .map_err(|e| OpenMlsError::MlsError(format!("Failed to create KeyPackage: {:?}", e)))?
            .key_package()
            .clone();

        // Serialize as MLSMessage
        let kp_bytes = MlsMessageOut::from(key_package)
            .tls_serialize_detached()
            .map_err(|e| {
                OpenMlsError::SerializationError(format!("Failed to serialize KeyPackage: {:?}", e))
            })?;

        // Wrap in CBOR array per protocol spec: KeyPackageArray = [* bstr]
        let mut cbor = Vec::new();
        ciborium::into_writer(&vec![kp_bytes], &mut cbor).map_err(|e| {
            OpenMlsError::SerializationError(format!("Failed to encode CBOR: {:?}", e))
        })?;

        Ok(cbor)
    }

    /// Create a new MLS group with random 16-byte group_id
    pub fn create_group(&self) -> Result<String, OpenMlsError> {
        // Generate random 16-byte group ID
        let group_id_bytes: [u8; 16] = rand::random();
        let group_id = hex::encode(group_id_bytes);

        let config = MlsGroupCreateConfig::builder()
            .ciphersuite(CIPHERSUITE)
            .use_ratchet_tree_extension(true)
            .build();

        let group = MlsGroup::new_with_group_id(
            &self.backend,
            &self.signer,
            &config,
            GroupId::from_slice(&group_id_bytes),
            self.credential.clone(),
        )
        .map_err(|e| OpenMlsError::MlsError(format!("Failed to create group: {:?}", e)))?;

        self.groups
            .lock()
            .unwrap()
            .insert(group_id.clone(), group);

        Ok(group_id)
    }

    /// Add a member to a group using their KeyPackage (CBOR-wrapped)
    pub fn add_member(
        &self,
        group_id: String,
        key_package_bytes: Vec<u8>,
    ) -> Result<AddMemberResult, OpenMlsError> {
        // Decode CBOR array
        let kp_array: Vec<Vec<u8>> = ciborium::from_reader(key_package_bytes.as_slice())
            .map_err(|e| {
                OpenMlsError::SerializationError(format!("Failed to decode CBOR: {:?}", e))
            })?;

        let kp_mls_bytes = kp_array
            .first()
            .ok_or_else(|| OpenMlsError::InvalidInput("Empty KeyPackage array".to_string()))?;

        // Deserialize MLSMessage
        let mls_msg = MlsMessageIn::tls_deserialize(&mut kp_mls_bytes.as_slice()).map_err(|e| {
            OpenMlsError::SerializationError(format!("Failed to deserialize KeyPackage: {:?}", e))
        })?;

        // Extract KeyPackage
        let key_package = match mls_msg.extract() {
            MlsMessageBodyIn::KeyPackage(kp) => kp
                .validate(self.backend.crypto(), ProtocolVersion::Mls10)
                .map_err(|e| {
                    OpenMlsError::MlsError(format!("Failed to validate KeyPackage: {:?}", e))
                })?,
            _ => {
                return Err(OpenMlsError::InvalidInput(
                    "Expected KeyPackage message".to_string(),
                ))
            }
        };

        let mut groups = self.groups.lock().unwrap();
        let group = groups
            .get_mut(&group_id)
            .ok_or(OpenMlsError::GroupNotFound)?;

        // Add member
        let (commit, welcome, _group_info) = group
            .add_members(&self.backend, &self.signer, &[key_package])
            .map_err(|e| OpenMlsError::MlsError(format!("Failed to add member: {:?}", e)))?;

        // Merge pending commit
        group
            .merge_pending_commit(&self.backend)
            .map_err(|e| OpenMlsError::MlsError(format!("Failed to merge commit: {:?}", e)))?;

        // Serialize results
        let welcome_bytes = welcome.tls_serialize_detached().map_err(|e| {
            OpenMlsError::SerializationError(format!("Failed to serialize Welcome: {:?}", e))
        })?;

        let commit_bytes = commit.tls_serialize_detached().map_err(|e| {
            OpenMlsError::SerializationError(format!("Failed to serialize Commit: {:?}", e))
        })?;

        Ok(AddMemberResult {
            welcome_bytes,
            commit_bytes,
        })
    }

    /// Join a group from a Welcome message
    pub fn join_from_welcome(&self, welcome_bytes: Vec<u8>) -> Result<JoinGroupResult, OpenMlsError> {
        // Deserialize Welcome
        let mls_msg = MlsMessageIn::tls_deserialize(&mut welcome_bytes.as_slice()).map_err(|e| {
            OpenMlsError::SerializationError(format!("Failed to deserialize Welcome: {:?}", e))
        })?;

        let welcome = match mls_msg.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => {
                return Err(OpenMlsError::InvalidInput(
                    "Expected Welcome message".to_string(),
                ))
            }
        };

        // Join group
        let config = MlsGroupJoinConfig::builder().build();
        let group =
            StagedWelcome::new_from_welcome(&self.backend, &config, welcome, None)
                .map_err(|e| OpenMlsError::MlsError(format!("Failed to stage Welcome: {:?}", e)))?
                .into_group(&self.backend)
                .map_err(|e| OpenMlsError::MlsError(format!("Failed to join group: {:?}", e)))?;

        let group_id = hex::encode(group.group_id().as_slice());

        self.groups.lock().unwrap().insert(group_id.clone(), group);

        Ok(JoinGroupResult { group_id })
    }

    /// Encrypt a message for a group
    pub fn encrypt(&self, group_id: String, plaintext: Vec<u8>) -> Result<Vec<u8>, OpenMlsError> {
        let mut groups = self.groups.lock().unwrap();
        let group = groups
            .get_mut(&group_id)
            .ok_or(OpenMlsError::GroupNotFound)?;

        let ciphertext = group
            .create_message(&self.backend, &self.signer, &plaintext)
            .map_err(|e| OpenMlsError::MlsError(format!("Failed to encrypt: {:?}", e)))?;

        ciphertext.tls_serialize_detached().map_err(|e| {
            OpenMlsError::SerializationError(format!("Failed to serialize ciphertext: {:?}", e))
        })
    }

    /// Decrypt a message from a group
    pub fn decrypt(
        &self,
        group_id: String,
        ciphertext: Vec<u8>,
    ) -> Result<DecryptedMessage, OpenMlsError> {
        let mut groups = self.groups.lock().unwrap();
        let group = groups
            .get_mut(&group_id)
            .ok_or(OpenMlsError::GroupNotFound)?;

        // Deserialize message
        let mls_msg = MlsMessageIn::tls_deserialize(&mut ciphertext.as_slice()).map_err(|e| {
            OpenMlsError::SerializationError(format!("Failed to deserialize message: {:?}", e))
        })?;

        // Extract ProtocolMessage
        let protocol_msg: ProtocolMessage = match mls_msg.extract() {
            MlsMessageBodyIn::PrivateMessage(pm) => pm.into(),
            MlsMessageBodyIn::PublicMessage(pm) => pm.into(),
            _ => {
                return Err(OpenMlsError::InvalidInput(
                    "Invalid message type".to_string(),
                ))
            }
        };

        // Process message
        let processed = group
            .process_message(&self.backend, protocol_msg)
            .map_err(|e| OpenMlsError::MlsError(format!("Failed to process message: {:?}", e)))?;

        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app_msg) => {
                let plaintext = app_msg.into_bytes();
                Ok(DecryptedMessage {
                    plaintext,
                    sender_client_id: "unknown".to_string(),
                })
            }
            ProcessedMessageContent::StagedCommitMessage(staged) => {
                group
                    .merge_staged_commit(&self.backend, *staged)
                    .map_err(|e| {
                        OpenMlsError::MlsError(format!("Failed to merge commit: {:?}", e))
                    })?;
                Err(OpenMlsError::InvalidInput(
                    "Received commit, not application message".to_string(),
                ))
            }
            _ => Err(OpenMlsError::InvalidInput(
                "Received proposal, not application message".to_string(),
            )),
        }
    }

    /// Get list of member client IDs in a group
    pub fn members(&self, group_id: String) -> Result<Vec<String>, OpenMlsError> {
        let groups = self.groups.lock().unwrap();
        let group = groups.get(&group_id).ok_or(OpenMlsError::GroupNotFound)?;

        Ok(group
            .members()
            .map(|m| String::from_utf8_lossy(m.credential.serialized_content()).to_string())
            .collect())
    }
}

// ============================================================================
// Legacy Functions (for backwards compatibility)
// ============================================================================

/// Generate a new client identity with a random client ID
pub fn generate_client_identity(client_id: String) -> Result<ClientIdentity, OpenMlsError> {
    // Create basic credential
    let credential = BasicCredential::new(client_id.clone().into_bytes());

    // Generate signature keypair
    let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).map_err(|e| {
        OpenMlsError::MlsError(format!("Failed to generate signature keypair: {:?}", e))
    })?;

    // Serialize credential - convert to Credential first
    let cred: Credential = credential.into();
    let credential_bytes = cred.tls_serialize_detached().map_err(|e| {
        OpenMlsError::SerializationError(format!("Failed to serialize credential: {:?}", e))
    })?;

    // Get public key bytes
    let public_key_bytes = signer.public().to_vec();

    Ok(ClientIdentity {
        client_id,
        credential_bytes,
        signature_public_key: public_key_bytes,
    })
}

/// Create a KeyPackage for the client (legacy - creates new signer each time)
pub fn create_key_package(client_id: String) -> Result<KeyPackageBundle, OpenMlsError> {
    let backend = OpenMlsRustCrypto::default();

    // Create credential
    let credential = BasicCredential::new(client_id.into_bytes());

    // Generate signature keypair
    let signer = SignatureKeyPair::new(CIPHERSUITE.signature_algorithm()).map_err(|e| {
        OpenMlsError::MlsError(format!("Failed to generate signature keypair: {:?}", e))
    })?;

    let credential_with_key = CredentialWithKey {
        credential: credential.into(),
        signature_key: signer.public().into(),
    };

    // Create KeyPackage
    let key_package_bundle = KeyPackage::builder()
        .build(CIPHERSUITE, &backend, &signer, credential_with_key)
        .map_err(|e| OpenMlsError::MlsError(format!("Failed to create KeyPackage: {:?}", e)))?;

    // Serialize KeyPackage
    let key_package_bytes = key_package_bundle
        .key_package()
        .tls_serialize_detached()
        .map_err(|e| {
            OpenMlsError::SerializationError(format!("Failed to serialize KeyPackage: {:?}", e))
        })?;

    // Get hash
    let hash_bytes = key_package_bundle
        .key_package()
        .hash_ref(backend.crypto())
        .map_err(|e| OpenMlsError::MlsError(format!("Failed to compute KeyPackage hash: {:?}", e)))?
        .as_slice()
        .to_vec();

    Ok(KeyPackageBundle {
        key_package_bytes,
        key_package_hash: hash_bytes,
    })
}

// ============================================================================
// Legacy OpenMlsGroup (for backwards compatibility)
// ============================================================================

pub struct OpenMlsGroup {
    inner: Arc<Mutex<MlsGroup>>,
    backend: Arc<OpenMlsRustCrypto>,
    signer: Arc<SignatureKeyPair>,
}

impl OpenMlsGroup {
    /// Create a new MLS group
    pub fn new(group_id: String, client_id: String) -> Result<Self, OpenMlsError> {
        let backend = Arc::new(OpenMlsRustCrypto::default());

        // Create credential
        let credential = BasicCredential::new(client_id.clone().into_bytes());

        // Create signer
        let signer = Arc::new(
            SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
                .map_err(|e| OpenMlsError::MlsError(format!("Failed to create signer: {:?}", e)))?,
        );

        let credential_with_key = CredentialWithKey {
            credential: credential.into(),
            signature_key: signer.public().into(),
        };

        // Parse group ID (try hex first, fallback to raw bytes)
        let group_id_bytes =
            hex::decode(&group_id).unwrap_or_else(|_| group_id.as_bytes().to_vec());
        let openmls_group_id = GroupId::from_slice(&group_id_bytes);

        let group = MlsGroup::new_with_group_id(
            backend.as_ref(),
            signer.as_ref(),
            &MlsGroupCreateConfig::default(),
            openmls_group_id,
            credential_with_key,
        )
        .map_err(|e| OpenMlsError::MlsError(format!("Failed to create group: {:?}", e)))?;

        Ok(Self {
            inner: Arc::new(Mutex::new(group)),
            backend,
            signer,
        })
    }

    /// Join a group from a Welcome message
    pub fn join_from_welcome(
        welcome_bytes: Vec<u8>,
        _client_id: String,
    ) -> Result<Self, OpenMlsError> {
        let backend = Arc::new(OpenMlsRustCrypto::default());

        // Deserialize Welcome
        let mls_message_in =
            MlsMessageIn::tls_deserialize(&mut welcome_bytes.as_slice()).map_err(|e| {
                OpenMlsError::SerializationError(format!("Failed to deserialize Welcome: {:?}", e))
            })?;

        // Extract Welcome from MlsMessageIn
        let welcome = match mls_message_in.extract() {
            MlsMessageBodyIn::Welcome(w) => w,
            _ => {
                return Err(OpenMlsError::InvalidInput(
                    "Not a Welcome message".to_string(),
                ))
            }
        };

        // Create signer
        let signer = Arc::new(
            SignatureKeyPair::new(CIPHERSUITE.signature_algorithm())
                .map_err(|e| OpenMlsError::MlsError(format!("Failed to create signer: {:?}", e)))?,
        );

        // Join group
        let group_config = MlsGroupJoinConfig::default();
        let group = StagedWelcome::new_from_welcome(
            backend.as_ref(),
            &group_config,
            welcome,
            None, // ratchet tree
        )
        .map_err(|e| OpenMlsError::MlsError(format!("Failed to stage Welcome: {:?}", e)))?
        .into_group(backend.as_ref())
        .map_err(|e| OpenMlsError::MlsError(format!("Failed to join group: {:?}", e)))?;

        Ok(Self {
            inner: Arc::new(Mutex::new(group)),
            backend,
            signer,
        })
    }

    /// Add a member to the group
    pub fn add_member(&self, key_package_bytes: Vec<u8>) -> Result<AddMemberResult, OpenMlsError> {
        let mut group = self.inner.lock().unwrap();

        // Deserialize KeyPackage
        let key_package_in = KeyPackageIn::tls_deserialize(&mut key_package_bytes.as_slice())
            .map_err(|e| {
                OpenMlsError::SerializationError(format!(
                    "Failed to deserialize KeyPackage: {:?}",
                    e
                ))
            })?;

        // Validate and convert to KeyPackage
        let key_package = key_package_in
            .validate(self.backend.crypto(), ProtocolVersion::default())
            .map_err(|e| {
                OpenMlsError::MlsError(format!("Failed to validate KeyPackage: {:?}", e))
            })?;

        // Add member
        let (commit, welcome, _group_info) = group
            .add_members(self.backend.as_ref(), self.signer.as_ref(), &[key_package])
            .map_err(|e| OpenMlsError::MlsError(format!("Failed to add member: {:?}", e)))?;

        // Merge pending commit
        group
            .merge_pending_commit(self.backend.as_ref())
            .map_err(|e| OpenMlsError::MlsError(format!("Failed to merge commit: {:?}", e)))?;

        // Serialize results
        let commit_bytes = commit.tls_serialize_detached().map_err(|e| {
            OpenMlsError::SerializationError(format!("Failed to serialize commit: {:?}", e))
        })?;

        let welcome_bytes = welcome.tls_serialize_detached().map_err(|e| {
            OpenMlsError::SerializationError(format!("Failed to serialize welcome: {:?}", e))
        })?;

        Ok(AddMemberResult {
            welcome_bytes,
            commit_bytes,
        })
    }

    /// Encrypt a message
    pub fn encrypt(&self, plaintext: Vec<u8>) -> Result<Vec<u8>, OpenMlsError> {
        let mut group = self.inner.lock().unwrap();

        let ciphertext = group
            .create_message(self.backend.as_ref(), self.signer.as_ref(), &plaintext)
            .map_err(|e| OpenMlsError::MlsError(format!("Failed to encrypt: {:?}", e)))?;

        ciphertext.tls_serialize_detached().map_err(|e| {
            OpenMlsError::SerializationError(format!("Failed to serialize ciphertext: {:?}", e))
        })
    }

    /// Decrypt a message
    pub fn decrypt(&self, ciphertext_bytes: Vec<u8>) -> Result<DecryptedMessage, OpenMlsError> {
        let mut group = self.inner.lock().unwrap();

        // Deserialize message
        let mls_message_in = MlsMessageIn::tls_deserialize(&mut ciphertext_bytes.as_slice())
            .map_err(|e| {
                OpenMlsError::SerializationError(format!("Failed to deserialize message: {:?}", e))
            })?;

        // Extract ProtocolMessage
        let protocol_message: ProtocolMessage = match mls_message_in.extract() {
            MlsMessageBodyIn::PrivateMessage(pm) => pm.into(),
            MlsMessageBodyIn::PublicMessage(pm) => pm.into(),
            _ => {
                return Err(OpenMlsError::InvalidInput(
                    "Invalid message type".to_string(),
                ))
            }
        };

        // Process message
        let processed = group
            .process_message(self.backend.as_ref(), protocol_message)
            .map_err(|e| OpenMlsError::MlsError(format!("Failed to process message: {:?}", e)))?;

        match processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(app_msg) => {
                let plaintext = app_msg.into_bytes();
                let sender_id = "unknown".to_string(); // TODO: extract sender from message

                Ok(DecryptedMessage {
                    plaintext,
                    sender_client_id: sender_id,
                })
            }
            ProcessedMessageContent::ProposalMessage(_) => Err(OpenMlsError::InvalidInput(
                "Received proposal, not application message".to_string(),
            )),
            ProcessedMessageContent::ExternalJoinProposalMessage(_) => Err(
                OpenMlsError::InvalidInput("Received external join proposal".to_string()),
            ),
            ProcessedMessageContent::StagedCommitMessage(_) => Err(OpenMlsError::InvalidInput(
                "Received commit, not application message".to_string(),
            )),
        }
    }

    /// Get the group ID as a hex string
    pub fn group_id(&self) -> String {
        let group = self.inner.lock().unwrap();
        hex::encode(group.group_id().as_slice())
    }

    /// Get list of member client IDs
    pub fn members(&self) -> Vec<String> {
        let group = self.inner.lock().unwrap();
        group
            .members()
            .map(|member| {
                String::from_utf8_lossy(member.credential.serialized_content()).to_string()
            })
            .collect()
    }
}

uniffi::include_scaffolding!("swift_openmls");
