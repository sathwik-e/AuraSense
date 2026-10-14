use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Classification of BLE devices with Apple Continuity awareness.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeviceCategory {
    IPhone,
    AppleWatch,
    AirPods,
    IPad,
    Mac,
    SecurityKey,
    GenericBle,
}

impl DeviceCategory {
    pub fn infer(name: &str, is_apple_continuity: bool) -> Self {
        let lower = name.to_lowercase();
        if lower.contains("iphone") {
            Self::IPhone
        } else if lower.contains("watch") {
            Self::AppleWatch
        } else if lower.contains("airpod") || lower.contains("beats") {
            Self::AirPods
        } else if lower.contains("ipad") {
            Self::IPad
        } else if lower.contains("macbook") || lower.contains("imac") {
            Self::Mac
        } else if lower.contains("yubi") || lower.contains("key") || lower.contains("tag") {
            Self::SecurityKey
        } else if is_apple_continuity {
            Self::IPhone
        } else {
            Self::GenericBle
        }
    }
}

/// Zero-allocation 1D Kalman + Exponential Moving Average filter for BLE RSSI telemetry.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct KalmanRssiFilter {
    estimate: f64,
    error_cov: f64,
    process_noise: f64,
    measurement_noise: f64,
}

impl KalmanRssiFilter {
    #[inline]
    pub fn new(initial_rssi: f64) -> Self {
        Self {
            estimate: initial_rssi,
            error_cov: 4.0,
            process_noise: 1.2,
            measurement_noise: 6.5,
        }
    }

    #[inline]
    pub fn update(&mut self, measurement: f64, ema_alpha: f64) -> f64 {
        let predicted_err = self.error_cov + self.process_noise;
        let kalman_gain = predicted_err / (predicted_err + self.measurement_noise);
        let kalman_est = self.estimate + kalman_gain * (measurement - self.estimate);
        self.error_cov = (1.0 - kalman_gain) * predicted_err;

        let alpha = ema_alpha.clamp(0.05, 0.95);
        self.estimate = (alpha * measurement) + ((1.0 - alpha) * kalman_est);
        self.estimate
    }

    #[inline]
    pub fn current(&self) -> f64 {
        self.estimate
    }
}

/// Decoded Apple Continuity (Manufacturer ID 0x004C) Nearby Info (Type 0x10) packet.
/// When an iPhone is unlocked via Face ID, iOS updates the Continuity status flags
/// in its BLE advertisement payload within ~100ms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ContinuityNearbyInfo {
    pub activity_level: u8,
    pub status_flags: u8,
    pub is_screen_on: bool,
    pub is_faceid_unlocked: bool,
    pub has_watch_paired: bool,
}

impl ContinuityNearbyInfo {
    /// Parses raw Manufacturer Specific Data (starting with 2-byte little-endian company ID 0x004C).
    pub fn parse_manufacturer_data(data: &[u8]) -> Option<Self> {
        if data.len() < 6 {
            return None;
        }
        let company_id = u16::from_le_bytes([data[0], data[1]]);
        if company_id != 0x004C {
            return None;
        }

        // Walk Continuity TLV sub-frames inside the 0x004C payload
        let mut idx = 2;
        while idx + 2 <= data.len() {
            let frame_type = data[idx];
            let frame_len = data[idx + 1] as usize;
            let payload_start = idx + 2;
            let payload_end = payload_start.saturating_add(frame_len);
            if payload_end > data.len() {
                break;
            }

            // Type 0x10 = Apple Continuity "Nearby Info"
            if frame_type == 0x10 && frame_len >= 2 {
                let activity_byte = data[payload_start];
                let status_flags = data[payload_start + 1];
                let activity_level = activity_byte & 0x0F;
                // In Continuity Nearby Info (0x10):
                // - Status flag bit 0x08 / activity level >= 0x07 indicates screen active & unlocked (Face ID verified)
                let is_faceid_unlocked = (status_flags & 0x08) != 0 || activity_level >= 0x07;
                let is_screen_on = (status_flags & 0x04) != 0 || is_faceid_unlocked;
                let has_watch_paired = (status_flags & 0x20) != 0;

                return Some(Self {
                    activity_level,
                    status_flags,
                    is_screen_on,
                    is_faceid_unlocked,
                    has_watch_paired,
                });
            }
            idx = payload_end;
        }
        None
    }
}

/// Discovered or bound BLE peripheral state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BleDevice {
    pub id: String,
    pub name: String,
    pub category: DeviceCategory,
    pub raw_rssi: i32,
    pub smoothed_rssi: f64,
    pub tx_power: i32,
    pub is_connected: bool,
    pub continuity_info: Option<ContinuityNearbyInfo>,
    pub last_seen_unix_ms: u64,
}

impl BleDevice {
    #[inline]
    pub fn estimated_distance_meters(&self) -> f64 {
        let rssi = self.smoothed_rssi.clamp(-100.0, -25.0);
        let tx = self.tx_power as f64;
        let path_loss = 2.2_f64;
        let dist = 10.0_f64.powf((tx - rssi) / (10.0 * path_loss));
        dist.clamp(0.1, 25.0)
    }

    pub fn now_unix_ms() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or(Duration::ZERO)
            .as_millis() as u64
    }
}

/// Represents the active macOS authentication dialog waiting for a password
/// (e.g., iCloud Keychain AutoFill in Safari, CoreAuthUI sheet, or SecurityAgent).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ActiveAuthPrompt {
    pub process_name: String,
    pub window_title: String,
    pub is_icloud_keychain_prompt: bool,
    pub is_secure_text_field_focused: bool,
}

/// External monitor & MacBook clamshell hardware state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct DisplayEnvironmentState {
    pub online_display_count: u32,
    pub has_external_monitor: bool,
    pub is_clamshell_closed: bool,
}

/// Method used to bridge iPhone Face ID to macOS iCloud Keychain Auto-Fill.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum FaceIdBridgeMethod {
    /// Mode 1: Local WebAuthn Passkey page served to iPhone Safari (Platform Authenticator + Face ID).
    WebAuthnPasskeyRelay,
    /// Mode 2: iOS Shortcut ("Authenticate with Face ID" -> Signed HMAC-SHA256 POST to Mac).
    IosShortcutHmacWebhook,
    /// Mode 3: Apple Continuity 0x004C Nearby Info (0x10) BLE Face ID Unlock Bit + Immediate Proximity.
    ContinuityBleFaceIdWake,
}

/// Persistent configuration for AuraSense Rust engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuraSenseRustConfig {
    pub monitoring_enabled: bool,
    pub selected_device_id: String,
    pub selected_device_name: String,
    pub unlock_threshold_rssi: f64,
    pub lock_threshold_rssi: f64,
    pub lock_grace_period_secs: u64,
    pub unlock_cooldown_secs: u64,
    pub ema_smoothing_alpha: f64,
    pub icloud_keychain_autofill_enabled: bool,
    pub require_external_monitor_for_keychain_autofill: bool,
    pub allow_continuity_ble_faceid_trigger: bool,
    pub passkey_relay_port: u16,
    #[serde(skip)]
    pub last_unlock_instant: Option<Instant>,
}

impl Default for AuraSenseRustConfig {
    fn default() -> Self {
        Self {
            monitoring_enabled: true,
            selected_device_id: String::new(),
            selected_device_name: String::from("iPhone"),
            unlock_threshold_rssi: -62.0,
            lock_threshold_rssi: -76.0,
            lock_grace_period_secs: 8,
            unlock_cooldown_secs: 5,
            ema_smoothing_alpha: 0.32,
            icloud_keychain_autofill_enabled: true,
            require_external_monitor_for_keychain_autofill: true,
            allow_continuity_ble_faceid_trigger: true,
            passkey_relay_port: 8765,
            last_unlock_instant: None,
        }
    }
}
