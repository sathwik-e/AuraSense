use crate::accessibility_autofill::MacAccessibilityController;
use crate::keychain::KeychainVault;
use crate::models::{
    AuraSenseRustConfig, BleDevice, ContinuityNearbyInfo, DeviceCategory, KalmanRssiFilter,
};
use std::collections::HashMap;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, PartialEq)]
pub enum ProximityEvaluationOutcome {
    NoAction,
    UnlockedMac { rssi: i32 },
    StartedGraceCountdown { remaining_secs: u64, rssi: i32 },
    CancelledGraceCountdown { rssi: i32 },
    LockedMac { rssi: i32 },
    AutoFilledIcloudKeychainViaContinuityFaceId { process: String, rssi: i32 },
}

/// High-frequency Rust BLE Proximity & Apple Continuity Face ID state machine.
pub struct BleProximityEngine {
    pub config: AuraSenseRustConfig,
    pub devices: HashMap<String, BleDevice>,
    filters: HashMap<String, KalmanRssiFilter>,
    previous_faceid_unlocked_state: HashMap<String, bool>,
    grace_started_at: Option<Instant>,
    last_keychain_autofill_at: Option<Instant>,
}

impl BleProximityEngine {
    pub fn new(config: AuraSenseRustConfig) -> Self {
        Self {
            config,
            devices: HashMap::new(),
            filters: HashMap::new(),
            previous_faceid_unlocked_state: HashMap::new(),
            grace_started_at: None,
            last_keychain_autofill_at: None,
        }
    }

    /// Processes an incoming BLE advertisement packet (and optional Manufacturer Data `0x004C`)
    /// in sub-microsecond time using the 1D Kalman + EMA filter.
    pub fn ingest_ble_packet(
        &mut self,
        device_id: &str,
        name: &str,
        raw_rssi: i32,
        tx_power: Option<i32>,
        is_connected: bool,
        manufacturer_data: Option<&[u8]>,
    ) -> ProximityEvaluationOutcome {
        if raw_rssi >= 0 || raw_rssi < -115 {
            return ProximityEvaluationOutcome::NoAction;
        }

        let filter = self
            .filters
            .entry(device_id.to_string())
            .or_insert_with(|| KalmanRssiFilter::new(raw_rssi as f64));
        let smoothed = filter.update(raw_rssi as f64, self.config.ema_smoothing_alpha);

        let continuity = manufacturer_data.and_then(ContinuityNearbyInfo::parse_manufacturer_data);
        let category = DeviceCategory::infer(name, continuity.is_some());

        let prev_unlocked = self
            .previous_faceid_unlocked_state
            .get(device_id)
            .copied()
            .unwrap_or(false);
        let now_unlocked = continuity.map(|c| c.is_faceid_unlocked).unwrap_or(false);
        self.previous_faceid_unlocked_state
            .insert(device_id.to_string(), now_unlocked);

        let device = BleDevice {
            id: device_id.to_string(),
            name: name.to_string(),
            category,
            raw_rssi,
            smoothed_rssi: smoothed,
            tx_power: tx_power.unwrap_or(-59),
            is_connected,
            continuity_info: continuity,
            last_seen_unix_ms: BleDevice::now_unix_ms(),
        };
        self.devices.insert(device_id.to_string(), device);

        if device_id != self.config.selected_device_id {
            return ProximityEvaluationOutcome::NoAction;
        }

        // Check Workaround 3: Apple Continuity 0x004C Nearby Info (0x10) Face ID Unlock Transition
        // If an iCloud Keychain / CoreAuthUI password sheet is waiting on the external monitor
        // and the bound iPhone within immediate range (>= -58 dBm) just unlocked via Face ID:
        if self.config.icloud_keychain_autofill_enabled
            && self.config.allow_continuity_ble_faceid_trigger
            && !prev_unlocked
            && now_unlocked
            && smoothed >= (self.config.unlock_threshold_rssi + 4.0)
        {
            if let Some(outcome) = self.try_autofill_waiting_keychain_prompt(smoothed.round() as i32)
            {
                return outcome;
            }
        }

        self.evaluate_lock_unlock_state(smoothed)
    }

    fn try_autofill_waiting_keychain_prompt(
        &mut self,
        current_rssi: i32,
    ) -> Option<ProximityEvaluationOutcome> {
        if let Some(last) = self.last_keychain_autofill_at {
            if last.elapsed() < Duration::from_secs(3) {
                return None;
            }
        }

        let display_env = MacAccessibilityController::query_display_environment();
        if self.config.require_external_monitor_for_keychain_autofill
            && !display_env.has_external_monitor
        {
            return None;
        }

        if let Some(prompt) = MacAccessibilityController::detect_active_icloud_keychain_prompt() {
            if prompt.is_secure_text_field_focused {
                if let Ok(Some(pw)) = KeychainVault::retrieve_macos_password() {
                    if MacAccessibilityController::autofill_password(&pw, false).is_ok() {
                        self.last_keychain_autofill_at = Some(Instant::now());
                        return Some(
                            ProximityEvaluationOutcome::AutoFilledIcloudKeychainViaContinuityFaceId {
                                process: prompt.process_name,
                                rssi: current_rssi,
                            },
                        );
                    }
                }
            }
        }
        None
    }

    pub fn evaluate_lock_unlock_state(&mut self, smoothed_rssi: f64) -> ProximityEvaluationOutcome {
        if !self.config.monitoring_enabled || self.config.selected_device_id.is_empty() {
            return ProximityEvaluationOutcome::NoAction;
        }

        let rssi_int = smoothed_rssi.round() as i32;

        // 1. Inside Unlock Aura
        if smoothed_rssi >= self.config.unlock_threshold_rssi {
            if self.grace_started_at.take().is_some() {
                return ProximityEvaluationOutcome::CancelledGraceCountdown { rssi: rssi_int };
            }

            if MacAccessibilityController::is_screen_locked() {
                let cooldown_ok = self
                    .config
                    .last_unlock_instant
                    .map(|t| t.elapsed() >= Duration::from_secs(self.config.unlock_cooldown_secs))
                    .unwrap_or(true);

                if cooldown_ok {
                    if let Ok(Some(password)) = KeychainVault::retrieve_macos_password() {
                        if MacAccessibilityController::autofill_password(&password, true).is_ok() {
                            self.config.last_unlock_instant = Some(Instant::now());
                            return ProximityEvaluationOutcome::UnlockedMac { rssi: rssi_int };
                        }
                    }
                }
            }
            return ProximityEvaluationOutcome::NoAction;
        }

        // 2. Outside Lock Boundary
        if smoothed_rssi <= self.config.lock_threshold_rssi {
            if let Some(started) = self.grace_started_at {
                let elapsed = started.elapsed().as_secs();
                if elapsed >= self.config.lock_grace_period_secs {
                    self.grace_started_at = None;
                    let _ = MacAccessibilityController::lock_mac_immediately();
                    return ProximityEvaluationOutcome::LockedMac { rssi: rssi_int };
                } else {
                    return ProximityEvaluationOutcome::StartedGraceCountdown {
                        remaining_secs: self.config.lock_grace_period_secs - elapsed,
                        rssi: rssi_int,
                    };
                }
            } else {
                self.grace_started_at = Some(Instant::now());
                return ProximityEvaluationOutcome::StartedGraceCountdown {
                    remaining_secs: self.config.lock_grace_period_secs,
                    rssi: rssi_int,
                };
            }
        }

        ProximityEvaluationOutcome::NoAction
    }
}

/// Result of the 10-second Desk Signal Calibration scan in Rust.
#[derive(Debug, Clone)]
pub struct DeskCalibrationResult {
    pub noted_desk_rssi_dbm: i32,
    pub jitter_std_dev_db: f64,
    pub optimized_unlock_rssi: f64,
    pub optimized_lock_rssi: f64,
    pub optimized_ema_alpha: f64,
    pub optimized_grace_secs: u64,
}

impl BleProximityEngine {
    /// Analyzes 10 seconds of desk RSSI samples to record the baseline desk signal strength
    /// and automatically tune Unlock/Lock thresholds, Kalman/EMA alpha, and grace period.
    pub fn finish_ten_second_desk_calibration(&mut self, samples: &[f64]) -> DeskCalibrationResult {
        let mut sorted: Vec<f64> = if samples.is_empty() {
            vec![-58.0]
        } else {
            samples.to_vec()
        };
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let n = sorted.len() as f64;
        let mean: f64 = sorted.iter().sum::<f64>() / n;
        let median = sorted[sorted.len() / 2];
        let variance = sorted.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / (n - 1.0).max(1.0);
        let std_dev = variance.sqrt().max(1.0);

        let unlock_margin = (1.8 * std_dev).clamp(4.0, 8.0);
        let hysteresis_gap = (3.5 * std_dev).clamp(11.0, 18.0);

        let opt_unlock = (median - unlock_margin).round().clamp(-80.0, -42.0);
        let opt_lock = (opt_unlock - hysteresis_gap).round().clamp(-94.0, opt_unlock - 8.0);

        let (opt_alpha, opt_grace) = if std_dev > 3.8 {
            (0.22, 10)
        } else if std_dev > 2.2 {
            (0.30, 8)
        } else {
            (0.38, 6)
        };

        self.config.unlock_threshold_rssi = opt_unlock;
        self.config.lock_threshold_rssi = opt_lock;
        self.config.ema_smoothing_alpha = opt_alpha;
        self.config.lock_grace_period_secs = opt_grace;

        DeskCalibrationResult {
            noted_desk_rssi_dbm: median.round() as i32,
            jitter_std_dev_db: (std_dev * 10.0).round() / 10.0,
            optimized_unlock_rssi: opt_unlock,
            optimized_lock_rssi: opt_lock,
            optimized_ema_alpha: opt_alpha,
            optimized_grace_secs: opt_grace,
        }
    }
}
