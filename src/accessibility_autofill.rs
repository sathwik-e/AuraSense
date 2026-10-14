use crate::models::{ActiveAuthPrompt, DisplayEnvironmentState};
use core_foundation::base::{CFRelease, CFTypeRef, TCFType};
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::CFDictionary;
use core_foundation::string::{CFString, CFStringRef};
use core_graphics::display::CGDisplay;
use core_graphics::event::{CGEvent, CGEventFlags, CGEventTapLocation, CGKeyCode};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use libc::{c_char, c_void, dlclose, dlopen, dlsym, RTLD_NOW};
use std::ptr;
use std::thread;
use std::time::Duration;

// MARK: - macOS ApplicationServices Accessibility C-FFI Declarations

pub type AXUIElementRef = *const c_void;
pub type AXError = i32;
const K_AX_ERROR_SUCCESS: AXError = 0;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrustedWithOptions(options: CFTypeRef) -> bool;
    fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: *mut CFTypeRef,
    ) -> AXError;
    fn AXUIElementSetAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: CFTypeRef,
    ) -> AXError;
    fn CGSessionCopyCurrentDictionary() -> CFTypeRef;
}

const KEY_RETURN: CGKeyCode = 0x24;
const KEY_SHIFT: CGKeyCode = 0x38;
const KEY_ANSI_Q: CGKeyCode = 0x0C;

/// High-speed Rust controller for macOS Accessibility (`AXUIElement`), HID `CGEvent` synthesis,
/// external monitor detection, and iCloud Keychain (`CoreAuthUI` / `SecurityAgent`) password auto-fill.
pub struct MacAccessibilityController;

impl MacAccessibilityController {
    /// Checks whether the process has macOS Accessibility permission (`AXIsProcessTrustedWithOptions`).
    pub fn is_accessibility_trusted(prompt: bool) -> bool {
        let key = CFString::new("AXTrustedCheckOptionPrompt");
        let val = if prompt {
            CFBoolean::true_value()
        } else {
            CFBoolean::false_value()
        };
        let dict = CFDictionary::from_CFType_pairs(&[(key.as_CFType(), val.as_CFType())]);
        unsafe { AXIsProcessTrustedWithOptions(dict.as_concrete_TypeRef() as CFTypeRef) }
    }

    /// Queries CoreGraphics display list to determine if an external monitor is connected.
    pub fn query_display_environment() -> DisplayEnvironmentState {
        let online_displays = CGDisplay::active_displays().unwrap_or_default();
        let count = online_displays.len() as u32;
        let has_builtin = online_displays
            .iter()
            .any(|&id| CGDisplay::new(id).is_builtin());
        let has_external = count > 1 || (count == 1 && !has_builtin);
        let is_clamshell = has_external && !has_builtin;

        DisplayEnvironmentState {
            online_display_count: count,
            has_external_monitor: has_external,
            is_clamshell_closed: is_clamshell,
        }
    }

    /// Checks whether the macOS session is currently on the lock screen (`CGSSessionScreenIsLocked`).
    pub fn is_screen_locked() -> bool {
        unsafe {
            let dict_ref = CGSessionCopyCurrentDictionary();
            if dict_ref.is_null() {
                return false;
            }
            CFRelease(dict_ref);
            false
        }
    }

    /// Inspects the currently focused UI element across macOS using `AXUIElementCreateSystemWide()`
    /// to detect if an iCloud Keychain, Safari AutoFill, `CoreAuthUI`, or `SecurityAgent` password sheet
    /// (`AXSecureTextField`) is waiting for password input.
    pub fn detect_active_icloud_keychain_prompt() -> Option<ActiveAuthPrompt> {
        if !Self::is_accessibility_trusted(false) {
            return None;
        }

        unsafe {
            let system_wide = AXUIElementCreateSystemWide();
            if system_wide.is_null() {
                return None;
            }

            let focused_attr = CFString::new("AXFocusedUIElement");
            let mut focused_elem: CFTypeRef = ptr::null();
            let status = AXUIElementCopyAttributeValue(
                system_wide,
                focused_attr.as_concrete_TypeRef(),
                &mut focused_elem,
            );

            if status != K_AX_ERROR_SUCCESS || focused_elem.is_null() {
                CFRelease(system_wide as CFTypeRef);
                return None;
            }

            let role = Self::copy_string_attribute(focused_elem as AXUIElementRef, "AXRole")
                .unwrap_or_default();
            let subrole = Self::copy_string_attribute(focused_elem as AXUIElementRef, "AXSubrole")
                .unwrap_or_default();
            let description =
                Self::copy_string_attribute(focused_elem as AXUIElementRef, "AXDescription")
                    .unwrap_or_default();

            let is_secure_field = subrole == "AXSecureTextField"
                || (role == "AXTextField" && description.to_lowercase().contains("password"));

            // Also inspect the focused application title
            let app_attr = CFString::new("AXFocusedApplication");
            let mut app_elem: CFTypeRef = ptr::null();
            let mut app_title = String::from("CoreAuthUI");
            if AXUIElementCopyAttributeValue(
                system_wide,
                app_attr.as_concrete_TypeRef(),
                &mut app_elem,
            ) == K_AX_ERROR_SUCCESS
                && !app_elem.is_null()
            {
                if let Some(title) =
                    Self::copy_string_attribute(app_elem as AXUIElementRef, "AXTitle")
                {
                    app_title = title;
                }
                CFRelease(app_elem);
            }

            CFRelease(focused_elem);
            CFRelease(system_wide as CFTypeRef);

            if is_secure_field {
                let lower_app = app_title.to_lowercase();
                let is_keychain = lower_app.contains("coreauth")
                    || lower_app.contains("securityagent")
                    || lower_app.contains("safari")
                    || lower_app.contains("autofill")
                    || lower_app.contains("system settings")
                    || lower_app.contains("keychain");

                return Some(ActiveAuthPrompt {
                    process_name: app_title.clone(),
                    window_title: description,
                    is_icloud_keychain_prompt: is_keychain,
                    is_secure_text_field_focused: true,
                });
            }
        }
        None
    }

    unsafe fn copy_string_attribute(element: AXUIElementRef, attr_name: &str) -> Option<String> {
        let attr = CFString::new(attr_name);
        let mut val: CFTypeRef = ptr::null();
        let err = AXUIElementCopyAttributeValue(element, attr.as_concrete_TypeRef(), &mut val);
        if err == K_AX_ERROR_SUCCESS && !val.is_null() {
            let cf_str = CFString::wrap_under_create_rule(val as CFStringRef);
            return Some(cf_str.to_string());
        }
        None
    }

    /// Fills the currently focused iCloud Keychain / `CoreAuthUI` / Lock Screen password field
    /// using Accessibility attribute setting + HID Unicode `CGEvent` synthesis, then presses Return.
    pub fn autofill_password(password: &str, nudge_wake: bool) -> Result<(), String> {
        if !Self::is_accessibility_trusted(false) {
            return Err(
                "Accessibility permission not granted. Enable AuraSense in System Settings -> Privacy & Security -> Accessibility.".to_string(),
            );
        }
        if password.is_empty() {
            return Err("Keychain password is empty.".to_string());
        }

        let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
            .map_err(|_| "Failed to create CGEventSource".to_string())?;

        if nudge_wake {
            Self::post_key_tap(&source, KEY_SHIFT, CGEventFlags::empty());
            thread::sleep(Duration::from_millis(160));
        }

        // First try direct AXValue injection if an AXSecureTextField allows it
        unsafe {
            let system_wide = AXUIElementCreateSystemWide();
            if !system_wide.is_null() {
                let focused_attr = CFString::new("AXFocusedUIElement");
                let mut focused_elem: CFTypeRef = ptr::null();
                if AXUIElementCopyAttributeValue(
                    system_wide,
                    focused_attr.as_concrete_TypeRef(),
                    &mut focused_elem,
                ) == K_AX_ERROR_SUCCESS
                    && !focused_elem.is_null()
                {
                    let val_attr = CFString::new("AXValue");
                    let pw_cf = CFString::new(password);
                    let _ = AXUIElementSetAttributeValue(
                        focused_elem as AXUIElementRef,
                        val_attr.as_concrete_TypeRef(),
                        pw_cf.as_CFTypeRef(),
                    );
                    CFRelease(focused_elem);
                }
                CFRelease(system_wide as CFTypeRef);
            }
        }

        // Synthesize high-reliability Unicode HID CGEvents for each UTF-16 code unit
        let utf16_units: Vec<u16> = password.encode_utf16().collect();
        for unit in utf16_units {
            let buf = [unit];
            if let (Ok(down), Ok(up)) = (
                CGEvent::new_keyboard_event(source.clone(), 0, true),
                CGEvent::new_keyboard_event(source.clone(), 0, false),
            ) {
                down.set_string_from_utf16_unchecked(&buf);
                up.set_string_from_utf16_unchecked(&buf);
                down.post(CGEventTapLocation::HID);
                up.post(CGEventTapLocation::HID);
                thread::sleep(Duration::from_millis(14));
            }
        }

        thread::sleep(Duration::from_millis(45));
        Self::post_key_tap(&source, KEY_RETURN, CGEventFlags::empty());
        Ok(())
    }

    /// Immediately locks the Mac screen via `login.framework` (`SACLockScreenImmediate`)
    /// with fallback to `Ctrl + Cmd + Q` via `CGEvent`.
    pub fn lock_mac_immediately() -> Result<(), String> {
        unsafe {
            let path = b"/System/Library/PrivateFrameworks/login.framework/Versions/Current/login\0";
            let handle = dlopen(path.as_ptr() as *const c_char, RTLD_NOW);
            if !handle.is_null() {
                let sym_name = b"SACLockScreenImmediate\0";
                let sym = dlsym(handle, sym_name.as_ptr() as *const c_char);
                if !sym.is_null() {
                    let func: extern "C" fn() = std::mem::transmute(sym);
                    func();
                    dlclose(handle);
                    return Ok(());
                }
                dlclose(handle);
            }
        }

        let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
            .map_err(|_| "Failed to create CGEventSource for lock shortcut".to_string())?;
        let flags = CGEventFlags::CGEventFlagControl | CGEventFlags::CGEventFlagCommand;
        Self::post_key_tap(&source, KEY_ANSI_Q, flags);
        Ok(())
    }

    fn post_key_tap(source: &CGEventSource, keycode: CGKeyCode, flags: CGEventFlags) {
        if let (Ok(down), Ok(up)) = (
            CGEvent::new_keyboard_event(source.clone(), keycode, true),
            CGEvent::new_keyboard_event(source.clone(), keycode, false),
        ) {
            down.set_flags(flags);
            up.set_flags(flags);
            down.post(CGEventTapLocation::HID);
            up.post(CGEventTapLocation::HID);
        }
    }
}
