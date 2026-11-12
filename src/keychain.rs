use security_framework::passwords::{
    delete_generic_password, get_generic_password, set_generic_password,
};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use std::fmt;
use std::fs::File;
use std::io::Read;

const UNLOCK_SERVICE: &str = "com.aurasense.mac.unlock-credentials";
const UNLOCK_ACCOUNT: &str = "macOSLoginPassword";

// Same Keychain item the AuraSense app uses, so one pairing link works for both.
const BRIDGE_TOKEN_SERVICE: &str = "com.aurasense.mac.bridge-token";
const BRIDGE_TOKEN_ACCOUNT: &str = "pairingToken";

#[derive(Debug)]
pub enum KeychainVaultError {
    SecurityFramework(String),
    InvalidUtf8,
}

impl fmt::Display for KeychainVaultError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SecurityFramework(msg) => write!(f, "macOS Keychain error: {}", msg),
            Self::InvalidUtf8 => write!(f, "Stored Keychain bytes are not valid UTF-8"),
        }
    }
}

impl std::error::Error for KeychainVaultError {}

/// Thread-safe Rust wrapper around macOS `Security.framework` Keychain storage.
pub struct KeychainVault;

impl KeychainVault {
    /// Stores or updates the user's macOS login password used for both screen unlock
    /// and iCloud Keychain / CoreAuthUI Accessibility auto-fill.
    pub fn save_macos_password(password: &str) -> Result<(), KeychainVaultError> {
        set_generic_password(UNLOCK_SERVICE, UNLOCK_ACCOUNT, password.as_bytes())
            .map_err(|e| KeychainVaultError::SecurityFramework(e.to_string()))
    }

    /// Retrieves the stored macOS login password from the login Keychain.
    pub fn retrieve_macos_password() -> Result<Option<String>, KeychainVaultError> {
        match get_generic_password(UNLOCK_SERVICE, UNLOCK_ACCOUNT) {
            Ok(bytes) => {
                let s = String::from_utf8(bytes).map_err(|_| KeychainVaultError::InvalidUtf8)?;
                if s.is_empty() {
                    Ok(None)
                } else {
                    Ok(Some(s))
                }
            }
            Err(_) => Ok(None),
        }
    }

    /// Removes the stored macOS password from the Keychain.
    pub fn delete_macos_password() -> Result<(), KeychainVaultError> {
        let _ = delete_generic_password(UNLOCK_SERVICE, UNLOCK_ACCOUNT);
        Ok(())
    }

    /// Returns the per-install pairing token every fill request must present. It is read from
    /// the Keychain item shared with the AuraSense app, or created from 32 random bytes.
    /// Fails (rather than falling back to a guessable value) if no random bytes are available.
    pub fn get_or_create_pairing_token() -> Result<String, KeychainVaultError> {
        if let Ok(bytes) = get_generic_password(BRIDGE_TOKEN_SERVICE, BRIDGE_TOKEN_ACCOUNT) {
            if let Ok(token) = String::from_utf8(bytes) {
                if is_well_formed_token(&token) {
                    return Ok(token);
                }
            }
        }

        let mut random = [0u8; 32];
        File::open("/dev/urandom")
            .and_then(|mut f| f.read_exact(&mut random))
            .map_err(|e| KeychainVaultError::SecurityFramework(format!("no random source: {}", e)))?;
        let token = URL_SAFE_NO_PAD.encode(random);
        set_generic_password(BRIDGE_TOKEN_SERVICE, BRIDGE_TOKEN_ACCOUNT, token.as_bytes())
            .map_err(|e| KeychainVaultError::SecurityFramework(e.to_string()))?;
        Ok(token)
    }
}

fn is_well_formed_token(token: &str) -> bool {
    token.len() >= 43
        && token
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
