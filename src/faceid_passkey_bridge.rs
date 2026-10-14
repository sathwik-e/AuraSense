use crate::accessibility_autofill::MacAccessibilityController;
use crate::keychain::KeychainVault;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha256 = Hmac<Sha256>;

/// Local LAN POST `/api/v1/faceid-autofill` & `/faceid` Home Screen Trigger Server.
/// Serves a clean, unlocked webpage version on iPhone with instant POST trigger
/// and instructions to add the POST Shortcut to the iPhone Home Screen.
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
            "[AuraSense-Rust] Prioritized POST /api/v1/faceid-autofill & /faceid server listening on http://{}",
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
        } else {
            let html = Self::mobile_unlocked_webpage_html();
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
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
<title>AuraSense • Keychain Auto-Fill</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 20px 16px 44px;
    background: radial-gradient(circle at 50% 0%, #172347 0%, #070912 65%);
    color: #f5f7ff;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif;
    display: flex; flex-direction: column; align-items: center;
  }
  .container { width: 100%; max-width: 440px; }
  .hero {
    text-align: center; padding: 22px 18px; border-radius: 22px;
    background: rgba(255,255,255,0.05); border: 1px solid rgba(41,217,245,0.35);
    margin-bottom: 18px;
  }
  .pill {
    display: inline-block; padding: 4px 11px; border-radius: 99px;
    background: rgba(41,240,166,0.14); border: 1px solid rgba(41,240,166,0.45);
    color: #29f0a6; font-size: 11px; font-weight: 700; margin-bottom: 10px;
  }
  h1 { font-size: 22px; margin: 0 0 6px; font-weight: 800; }
  .sub { font-size: 13px; color: rgba(255,255,255,0.72); line-height: 1.45; margin: 0 0 18px; }
  .btn-post {
    width: 100%; padding: 16px 18px; border-radius: 15px; border: none;
    background: linear-gradient(135deg, #29d9f5 0%, #6b5cfa 55%, #8c38f5 100%);
    color: #fff; font-size: 16px; font-weight: 700; cursor: pointer;
  }
  #status { margin-top: 12px; color: #29f0a6; font-size: 13px; font-weight: 600; }
  .card {
    background: rgba(255,255,255,0.045); border: 1px solid rgba(255,255,255,0.12);
    border-radius: 18px; padding: 18px; margin-bottom: 16px;
  }
  .card h2 { font-size: 15px; margin: 0 0 10px; color: #29d9f5; }
  .code-box {
    background: rgba(0,0,0,0.45); border: 1px solid rgba(41,217,245,0.3);
    padding: 10px 12px; border-radius: 10px; font-family: monospace;
    font-size: 12px; color: #29f0a6; word-break: break-all; margin: 8px 0 12px;
  }
  ol { margin: 0; padding-left: 20px; font-size: 13.5px; line-height: 1.58; color: rgba(255,255,255,0.88); }
  ol li { margin-bottom: 9px; }
</style>
</head>
<body>
  <div class="container">
    <div class="hero">
      <div class="pill">INSTANT POST TRIGGER • NO WEB APP LOCK</div>
      <h1>AuraSense Keychain Fill</h1>
      <p class="sub">Tap below to immediately fill your Mac's active iCloud Keychain or system password prompt.</p>
      <button class="btn-post" onclick="sendPostAutoFill()">⚡ Fill Mac Password Now (POST)</button>
      <div id="status"></div>
    </div>

    <div class="card">
      <h2>📲 Add POST Shortcut to iPhone Home Screen</h2>
      <div class="code-box">POST http://192.168.1.8:8765/api/v1/faceid-autofill</div>
      <ol>
        <li>Open <strong>Shortcuts</strong> on your iPhone → tap <strong>+</strong> → name it <strong>"Mac Keychain Fill"</strong>.</li>
        <li>Tap <strong>Add Action</strong> → select <strong>"Get Contents of URL"</strong>.</li>
        <li>Set URL to <strong>http://192.168.1.8:8765/api/v1/faceid-autofill</strong>, tap <strong>(&gt;)</strong>, and set <strong>Method</strong> to <strong><code>POST</code></strong>.</li>
        <li>Tap <strong>ⓘ (Info)</strong> or <strong>Share</strong> at the bottom → tap <strong>"Add to Home Screen"</strong> → tap <strong>Add</strong>.</li>
      </ol>
    </div>
  </div>
<script>
async function sendPostAutoFill() {
  const st = document.getElementById('status');
  st.textContent = 'Sending POST to /api/v1/faceid-autofill...';
  try {
    const res = await fetch('/api/v1/faceid-autofill', { method: 'POST' });
    const data = await res.json();
    st.textContent = data.ok ? ('✓ ' + data.message) : ('⚠ ' + (data.message || data.error));
  } catch (e) {
    st.textContent = 'Error: ' + e.message;
  }
}
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
