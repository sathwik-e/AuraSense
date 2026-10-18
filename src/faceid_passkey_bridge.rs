use crate::accessibility_autofill::MacAccessibilityController;
use crate::keychain::KeychainVault;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha256 = Hmac<Sha256>;

/// Local LAN POST `/api/v1/faceid-autofill` & `/faceid` Home Screen Trigger Server (v1.0).
/// Automatically triggers password auto-fill the instant `/api/v1/faceid-autofill` or `/faceid`
/// is opened in the browser.
pub struct FaceIdPasskeyBridgeServer {
    pub port: u16,
}

impl FaceIdPasskeyBridgeServer {
    pub fn new(port: u16) -> Self {
        Self { port }
    }

    pub fn verify_hmac_token(timestamp_sec: u64, provided_hex_mac: &str) -> bool {
        let now_sec = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);

        if now_sec.abs_diff(timestamp_sec) > 30 {
            return false;
        }

        let secret = KeychainVault::get_or_create_faceid_pairing_secret();
        let Ok(mut mac) = HmacSha256::new_from_slice(secret.as_bytes()) else {
            return false;
        };
        let payload = format!("aurasense-faceid-unlock:{}", timestamp_sec);
        mac.update(payload.as_bytes());
        let expected_bytes = mac.finalize().into_bytes();
        let expected_hex: String = expected_bytes.iter().map(|b| format!("{:02x}", b)).collect();

        constant_time_eq(expected_hex.as_bytes(), provided_hex_mac.trim().as_bytes())
    }

    pub fn run_blocking(&self) -> std::io::Result<()> {
        let addr = format!("0.0.0.0:{}", self.port);
        let listener = TcpListener::bind(&addr)?;
        println!(
            "[AuraSense-Rust v1.0] Auto-Fill server listening on http://{}",
            addr
        );

        for stream in listener.incoming() {
            if let Ok(mut s) = stream {
                let _ = self.handle_client(&mut s);
            }
        }
        Ok(())
    }

    fn handle_client(&self, stream: &mut TcpStream) -> std::io::Result<()> {
        let mut buf = [0u8; 4096];
        let n = stream.read(&mut buf)?;
        if n == 0 {
            return Ok(());
        }
        let req = String::from_utf8_lossy(&buf[..n]);
        let first_line = req.lines().next().unwrap_or("");

        if first_line.starts_with("POST /api/v1/faceid-autofill")
            || first_line.starts_with("POST /api/v1/passkey-assert")
            || first_line.starts_with("POST /faceid")
        {
            let result = Self::trigger_keychain_autofill_now();
            let (status, json_body) = match result {
                Ok(target) => (
                    "200 OK",
                    format!(
                        "{{\"ok\":true,\"method\":\"POST /api/v1/faceid-autofill\",\"message\":\"Auto-filled Mac password into {}\"}}",
                        target
                    ),
                ),
                Err(err) => (
                    "400 Bad Request",
                    format!("{{\"ok\":false,\"error\":\"{}\"}}", err),
                ),
            };
            let resp = format!(
                "HTTP/1.1 {}\r\nContent-Type: application/json; charset=utf-8\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                status,
                json_body.len(),
                json_body
            );
            stream.write_all(resp.as_bytes())?;
        } else if first_line.starts_with("GET /favicon") {
            let resp = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n";
            stream.write_all(resp.as_bytes())?;
        } else {
            let _ = Self::trigger_keychain_autofill_now();
            let html = Self::mobile_unlocked_webpage_html();
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store, no-cache, must-revalidate\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                html.len(),
                html
            );
            stream.write_all(resp.as_bytes())?;
        }
        Ok(())
    }

    pub fn trigger_keychain_autofill_now() -> Result<String, String> {
        let Some(password) = KeychainVault::retrieve_macos_password().map_err(|e| e.to_string())?
        else {
            return Err("No macOS password stored in AuraSense Keychain Vault".to_string());
        };

        let target_name = MacAccessibilityController::detect_active_icloud_keychain_prompt()
            .map(|p| p.process_name)
            .unwrap_or_else(|| "Active macOS Password Field".to_string());

        MacAccessibilityController::autofill_password(&password, false)?;
        Ok(target_name)
    }

    fn mobile_unlocked_webpage_html() -> &'static str {
        r#"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"/>
<title>AuraSense v1.0</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 24px 16px 40px;
    background: #02040a; color: #f5f9ff;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
    display: flex; flex-direction: column; align-items: center;
  }
  .container { width: 100%; max-width: 420px; }
  .hero {
    text-align: center; padding: 26px 18px 22px; border-radius: 24px;
    background: radial-gradient(circle at 50% 35%, #071936 0%, #03060e 75%);
    border: 1px solid rgba(56, 214, 255, 0.35);
    margin-bottom: 16px;
  }
  .wordmark { font-size: 18px; font-weight: 300; letter-spacing: 5px; margin: 10px 0 8px; }
  .wordmark .sense { color: #38d6ff; }
  .sub { font-size: 13px; color: rgba(255,255,255,0.72); margin: 0 0 16px; }
  .btn-post {
    width: 100%; padding: 15px 18px; border-radius: 14px; border: none;
    background: linear-gradient(135deg, #1f5eff 0%, #29c4ff 60%, #38f2ee 100%);
    color: #020610; font-size: 15px; font-weight: 700; cursor: pointer;
  }
  #status { margin-top: 12px; color: #38f2ee; font-size: 13px; font-weight: 600; }
  .card {
    background: rgba(255,255,255,0.03); border: 1px solid rgba(255,255,255,0.10);
    border-radius: 18px; padding: 16px;
  }
  .card h2 { font-size: 14px; margin: 0 0 10px; color: #38d6ff; }
  .code-box {
    background: #000; border: 1px solid rgba(56,214,255,0.28);
    padding: 9px 11px; border-radius: 9px; font-family: monospace;
    font-size: 12px; color: #38f2ee; word-break: break-all; margin-bottom: 12px;
  }
  ol { margin: 0; padding-left: 18px; font-size: 13px; line-height: 1.55; color: rgba(255,255,255,0.85); }
  ol li { margin-bottom: 7px; }
</style>
</head>
<body>
  <div class="container">
    <div class="hero">
      <svg viewBox="0 0 120 120" width="96" height="96">
        <defs>
          <linearGradient id="g" x1="0%" y1="100%" x2="100%" y2="0%">
            <stop offset="0%" stop-color="#1f5eff"/><stop offset="100%" stop-color="#38f2ee"/>
          </linearGradient>
        </defs>
        <circle cx="60" cy="60" r="52" fill="none" stroke="url(#g)" stroke-width="2.5"/>
        <path d="M 34 62 A 28 28 0 1 1 86 62 A 26.5 26.5 0 1 0 34 62 Z" fill="url(#g)"/>
      </svg>
      <div class="wordmark"><span>ΛURΛ</span><span class="sense">SENSE</span></div>
      <p class="sub">Mac password auto-fills as soon as this page opens.</p>
      <button class="btn-post" onclick="sendPostAutoFill()">Fill Mac Password Again</button>
      <div id="status">Auto-filling Mac password...</div>
    </div>
    <div class="card">
      <h2>Quick Setup</h2>
      <div class="code-box">http://192.168.1.8:8765/api/v1/faceid-autofill</div>
      <ol>
        <li><strong>Home Screen Icon</strong>: Tap <strong>Share &gt; Add to Home Screen</strong> in Safari.</li>
        <li><strong>iOS Shortcut (POST)</strong>: In <strong>Shortcuts</strong>, add <strong>Get Contents of URL</strong> with the URL above and set Method to <strong>POST</strong>.</li>
      </ol>
    </div>
  </div>
<script>
async function sendPostAutoFill() {
  const st = document.getElementById('status');
  st.textContent = 'Filling Mac password...';
  try {
    const res = await fetch('/api/v1/faceid-autofill', { method: 'POST' });
    const data = await res.json();
    st.textContent = data.ok ? 'Mac password filled.' : (data.message || data.error);
  } catch (e) {
    st.textContent = 'Connection error: ' + e.message;
  }
}
window.addEventListener('DOMContentLoaded', () => { sendPostAutoFill(); });
window.addEventListener('pageshow', (e) => { if (e.persisted) sendPostAutoFill(); });
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') sendPostAutoFill(); });
</script>
</body>
</html>"#
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (&x, &y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}
