use crate::accessibility_autofill::MacAccessibilityController;
use crate::keychain::KeychainVault;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::time::Duration;

const MAX_REQUEST_BYTES: usize = 16 * 1024;
const TOKEN_HEADER: &str = "x-aurasense-token";
const FILL_PATHS: [&str; 3] = ["/api/v1/faceid-autofill", "/api/v1/passkey-assert", "/faceid"];
const PAGE_PATHS: [&str; 3] = ["/", "/faceid", "/api/v1/faceid-autofill"];

/// iPhone -> Mac password fill bridge for the standalone Rust daemon.
///
/// It follows the same rules as the AuraSense app's bridge: every request must carry the
/// per-install pairing token (header `X-AuraSense-Token` or query `t=`), a GET only serves the
/// page and never fills, and a fill only targets the lock screen or a macOS system password
/// prompt. Do not run it at the same time as the app: both listen on the same port.
pub struct FaceIdPasskeyBridgeServer {
    pub port: u16,
    token: String,
}

struct HttpRequest {
    method: String,
    path: String,
    query_token: Option<String>,
    header_token: Option<String>,
    origin: Option<String>,
    host: Option<String>,
}

impl FaceIdPasskeyBridgeServer {
    /// Fails if the pairing token cannot be read or created; the server must not run without one.
    pub fn new(port: u16) -> Result<Self, String> {
        let token = KeychainVault::get_or_create_pairing_token().map_err(|e| e.to_string())?;
        Ok(Self { port, token })
    }

    pub fn run_blocking(&self) -> std::io::Result<()> {
        let addr = format!("0.0.0.0:{}", self.port);
        let listener = TcpListener::bind(&addr)?;
        println!(
            "[AuraSense-Rust] Auto-Fill server listening on http://{} (pairing token required)",
            addr
        );

        for mut s in listener.incoming().flatten() {
            // A silent client must not be able to stall the single accept loop.
            let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
            let _ = s.set_write_timeout(Some(Duration::from_secs(5)));
            let _ = self.handle_client(&mut s);
        }
        Ok(())
    }

    fn handle_client(&self, stream: &mut TcpStream) -> std::io::Result<()> {
        let Some(request) = Self::read_request(stream)? else {
            return Self::send(stream, "400 Bad Request", "text/plain; charset=utf-8", "Bad request");
        };

        match request.method.as_str() {
            "GET" => {
                if request.path == "/favicon.ico" {
                    return Self::send(stream, "204 No Content", "text/plain; charset=utf-8", "");
                }
                if !PAGE_PATHS.contains(&request.path.as_str()) {
                    return Self::send(stream, "404 Not Found", "text/plain; charset=utf-8", "Not found");
                }
                // GET never fills. Only a request that already holds the token gets the page.
                if !self.is_valid_token(request.query_token.as_deref()) {
                    return Self::send(
                        stream,
                        "401 Unauthorized",
                        "text/plain; charset=utf-8",
                        "Missing or invalid AuraSense pairing token.",
                    );
                }
                Self::send(
                    stream,
                    "200 OK",
                    "text/html; charset=utf-8",
                    Self::mobile_unlocked_webpage_html(),
                )
            }
            "POST" => {
                if !FILL_PATHS.contains(&request.path.as_str()) {
                    return Self::send(stream, "404 Not Found", "text/plain; charset=utf-8", "Not found");
                }
                // A page from another site must not be able to trigger a fill.
                if let Some(origin) = &request.origin {
                    let host = request.host.clone().unwrap_or_default();
                    if host.is_empty() || origin.to_lowercase() != format!("http://{}", host.to_lowercase()) {
                        return Self::send_json(stream, "403 Forbidden", false, "Cross-origin requests are not allowed.");
                    }
                }
                let presented = request.header_token.as_deref().or(request.query_token.as_deref());
                if !self.is_valid_token(presented) {
                    return Self::send_json(
                        stream,
                        "401 Unauthorized",
                        false,
                        "Missing or invalid AuraSense pairing token.",
                    );
                }
                match Self::trigger_keychain_autofill_now() {
                    Ok(target) => Self::send_json(
                        stream,
                        "200 OK",
                        true,
                        &format!("Filled Mac password into {}", target),
                    ),
                    Err(err) => Self::send_json(stream, "409 Conflict", false, &err),
                }
            }
            _ => Self::send(stream, "405 Method Not Allowed", "text/plain; charset=utf-8", "Method not allowed"),
        }
    }

    /// Reads until the end of the HTTP headers. Returns `None` for a malformed or oversized request.
    fn read_request(stream: &mut TcpStream) -> std::io::Result<Option<HttpRequest>> {
        let mut data: Vec<u8> = Vec::new();
        let mut buf = [0u8; 4096];
        let header_end = loop {
            if let Some(pos) = data.windows(4).position(|w| w == b"\r\n\r\n") {
                break pos;
            }
            if data.len() > MAX_REQUEST_BYTES {
                return Ok(None);
            }
            let n = stream.read(&mut buf)?;
            if n == 0 {
                return Ok(None);
            }
            data.extend_from_slice(&buf[..n]);
        };

        let head = String::from_utf8_lossy(&data[..header_end]).to_string();
        let mut lines = head.split("\r\n");
        let request_line = lines.next().unwrap_or("");
        let mut parts = request_line.split(' ');
        let (Some(method), Some(target), Some(version)) = (parts.next(), parts.next(), parts.next()) else {
            return Ok(None);
        };
        if !version.starts_with("HTTP/1.") || !target.starts_with('/') {
            return Ok(None);
        }

        let (path, query) = match target.split_once('?') {
            Some((p, q)) => (p, q),
            None => (target, ""),
        };
        let query_token = query
            .split('&')
            .find_map(|pair| pair.strip_prefix("t="))
            .map(|t| t.to_string());

        let mut header_token = None;
        let mut origin = None;
        let mut host = None;
        for line in lines {
            let Some((name, value)) = line.split_once(':') else {
                continue;
            };
            let value = value.trim().to_string();
            match name.trim().to_lowercase().as_str() {
                TOKEN_HEADER => header_token = Some(value),
                "origin" => origin = Some(value),
                "host" => host = Some(value),
                _ => {}
            }
        }

        Ok(Some(HttpRequest {
            method: method.to_string(),
            path: path.to_string(),
            query_token,
            header_token,
            origin,
            host,
        }))
    }

    fn is_valid_token(&self, presented: Option<&str>) -> bool {
        match presented {
            Some(given) if !given.is_empty() => constant_time_eq(self.token.as_bytes(), given.as_bytes()),
            _ => false,
        }
    }

    fn send_json(stream: &mut TcpStream, status: &str, ok: bool, message: &str) -> std::io::Result<()> {
        let body = serde_json::json!({ "ok": ok, "message": message }).to_string();
        Self::send(stream, status, "application/json; charset=utf-8", &body)
    }

    fn send(stream: &mut TcpStream, status: &str, content_type: &str, body: &str) -> std::io::Result<()> {
        let head = format!(
            "HTTP/1.1 {}\r\nContent-Type: {}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            status,
            content_type,
            body.len()
        );
        stream.write_all(head.as_bytes())?;
        stream.write_all(body.as_bytes())
    }

    /// Types the stored password, but only into the lock screen or a focused macOS system
    /// password prompt. Anywhere else the keystrokes would land in whatever app has focus.
    pub fn trigger_keychain_autofill_now() -> Result<String, String> {
        let Some(password) = KeychainVault::retrieve_macos_password().map_err(|e| e.to_string())?
        else {
            return Err("No macOS password stored in the AuraSense Keychain item".to_string());
        };

        let target_name = if MacAccessibilityController::is_screen_locked() {
            "the lock screen".to_string()
        } else {
            match MacAccessibilityController::detect_active_icloud_keychain_prompt() {
                Some(prompt) if prompt.is_icloud_keychain_prompt => prompt.process_name,
                _ => {
                    return Err(
                        "Nothing filled: the Mac is unlocked and no macOS system password prompt has focus."
                            .to_string(),
                    )
                }
            }
        };

        MacAccessibilityController::autofill_password(&password, false)?;
        Ok(target_name)
    }

    fn mobile_unlocked_webpage_html() -> &'static str {
        r##"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"/>
<title>AuraSense</title>
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
      <p class="sub">Fills the Mac password prompt once when this page opens.</p>
      <button class="btn-post" onclick="sendPostAutoFill()">Fill Mac Password Again</button>
      <div id="status">Auto-filling Mac password...</div>
    </div>
    <div class="card">
      <h2>Quick Setup</h2>
      <ol>
        <li><strong>Home Screen Icon</strong>: Tap <strong>Share &gt; Add to Home Screen</strong> in Safari.</li>
        <li>Keep this link private. It contains your Mac's pairing token.</li>
      </ol>
    </div>
  </div>
<script>
const AURA_TOKEN = new URLSearchParams(window.location.search).get('t') || '';
let fillInFlight = false;
async function sendPostAutoFill() {
  if (fillInFlight) return;
  fillInFlight = true;
  const st = document.getElementById('status');
  st.textContent = 'Filling Mac password...';
  try {
    const res = await fetch('/api/v1/faceid-autofill', {
      method: 'POST',
      cache: 'no-store',
      headers: { 'X-AuraSense-Token': AURA_TOKEN }
    });
    const data = await res.json();
    st.textContent = data.ok ? 'Mac password filled.' : (data.message || 'Request refused.');
  } catch (e) {
    st.textContent = 'Connection error: ' + e.message;
  } finally {
    fillInFlight = false;
  }
}
// Exactly one automatic fill per page open; further fills need the button.
window.addEventListener('DOMContentLoaded', () => { sendPostAutoFill(); }, { once: true });
</script>
</body>
</html>"##
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
