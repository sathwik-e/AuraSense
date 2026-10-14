pub mod accessibility_autofill;
pub mod ble_engine;
pub mod faceid_passkey_bridge;
pub mod keychain;
pub mod models;

use accessibility_autofill::MacAccessibilityController;
use ble_engine::{BleProximityEngine, ProximityEvaluationOutcome};
use faceid_passkey_bridge::FaceIdPasskeyBridgeServer;
use keychain::KeychainVault;
use models::AuraSenseRustConfig;
use std::env;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

fn main() {
    let args: Vec<String> = env::args().collect();
    let config = AuraSenseRustConfig::default();

    if args.iter().any(|a| a == "--lock") {
        let _ = MacAccessibilityController::lock_mac_immediately();
        return;
    }

    if args.iter().any(|a| a == "--autofill-keychain" || a == "--unlock") {
        match FaceIdPasskeyBridgeServer::trigger_keychain_autofill_now() {
            Ok(target) => println!("[AuraSense-Rust] Auto-filled password into: {}", target),
            Err(e) => eprintln!("[AuraSense-Rust] Auto-fill error: {}", e),
        }
        return;
    }

    if args.iter().any(|a| a == "--status") {
        let trusted = MacAccessibilityController::is_accessibility_trusted(false);
        let disp = MacAccessibilityController::query_display_environment();
        let prompt = MacAccessibilityController::detect_active_icloud_keychain_prompt();
        println!(
            "{{\"accessibility_trusted\":{},\"displays\":{},\"external_monitor\":{},\"clamshell_closed\":{},\"active_auth_prompt\":{:?}}}",
            trusted,
            disp.online_display_count,
            disp.has_external_monitor,
            disp.is_clamshell_closed,
            prompt.map(|p| p.process_name)
        );
        return;
    }

    println!("==================================================================");
    println!("  AuraSense Rust Engine v1.1.0 (BLE Proximity + Face ID Bridge)");
    println!("==================================================================");
    println!(
        "  • Accessibility Trusted : {}",
        MacAccessibilityController::is_accessibility_trusted(false)
    );
    let disp = MacAccessibilityController::query_display_environment();
    println!(
        "  • Display Environment   : {} display(s) | External Monitor: {} | Clamshell: {}",
        disp.online_display_count, disp.has_external_monitor, disp.is_clamshell_closed
    );
    println!(
        "  • Keychain Vault Ready  : {}",
        KeychainVault::retrieve_macos_password()
            .ok()
            .flatten()
            .is_some()
    );
    println!(
        "  • Face ID Passkey Relay : http://0.0.0.0:{}/faceid",
        config.passkey_relay_port
    );
    println!("==================================================================");

    let engine = Arc::new(Mutex::new(BleProximityEngine::new(config.clone())));

    // Spawn the Local WebAuthn Passkey & iOS Shortcut Face ID Relay Server thread
    let bridge_port = config.passkey_relay_port;
    thread::spawn(move || {
        let server = FaceIdPasskeyBridgeServer::new(bridge_port);
        let _ = server.run_blocking();
    });

    // Main low-latency 10Hz Rust proximity & iCloud Keychain prompt watcher loop
    loop {
        if let Ok(mut eng) = engine.lock() {
            // Check if an iCloud Keychain / CoreAuthUI password dialog is currently waiting on an external display
            if let Some(prompt) = MacAccessibilityController::detect_active_icloud_keychain_prompt()
            {
                if prompt.is_icloud_keychain_prompt && prompt.is_secure_text_field_focused {
                    // Log detection so companion iPhone Face ID webhook or Continuity unlock bit can fill it immediately
                    let _ = &prompt.process_name;
                }
            }

            // Evaluate current BLE RSSI state
            if let Some(dev) = eng.devices.get(&eng.config.selected_device_id).cloned() {
                let outcome = eng.evaluate_lock_unlock_state(dev.smoothed_rssi);
                if outcome != ProximityEvaluationOutcome::NoAction {
                    println!("[AuraSense-Rust] State Transition: {:?}", outcome);
                }
            }
        }
        thread::sleep(Duration::from_millis(100));
    }
}
