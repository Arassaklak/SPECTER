# SPECTER

A private, self-hosted **remote desktop** between your **iPhone** and your **Windows PC**,
over your **local network** — end-to-end encrypted with **AES-256-GCM**, keyed by a
password only you know. No cloud, no accounts, no third-party relay. Just your two
devices talking directly over one TCP port.

```
   iPhone (SwiftUI app)                         Windows PC (Python server)
   ┌───────────────────┐                        ┌────────────────────────┐
   │ tiles → screen    │  ◀── AES-256-GCM ────  │ mss screen capture     │
   │ touch → mouse/kbd │  ──── AES-256-GCM ───▶ │ pynput input inject    │
   │ files / clipboard │  ◀───── LAN TCP ─────▶ │ files / clipboard      │
   └───────────────────┘   same Wi-Fi network   └────────────────────────┘
```

## What it does

- **Live screen** of the PC, streamed as JPEG **tiles with delta encoding** (only the
  parts of the screen that changed are sent → fast and light on Wi-Fi).
- **Full control**: touch → absolute mouse, gestures for click/right-click/scroll/drag,
  on-screen **and** hardware keyboard, modifier combos (Ctrl+C, Alt+Tab, …).
- **File transfer**, both directions, chunked and encrypted.
- **Clipboard sync**, both directions.
- **Quality presets** (crisp ↔ data-saver) you can switch live.

## Security in one paragraph

Your password never travels over the network. Both ends stretch it with
**PBKDF2-HMAC-SHA256 (210k iterations)** into a master key. A per-connection
**X25519** key exchange produces the actual session keys, so even if your password
leaked *tomorrow*, traffic captured *today* stays unreadable (**forward secrecy**).
Each side proves it knows the password by HMAC-ing the whole handshake transcript,
which also **prevents man-in-the-middle**. Every frame afterwards is sealed with
**AES-256-GCM** under a unique counter nonce (confidentiality + integrity + replay
protection). Full details in [docs/SECURITY.md](docs/SECURITY.md).

---

## Setup

### PC (server)

Requirements: Windows + Python 3.10+.

```powershell
cd C:\SPECTER\server
./run.ps1
```

`run.ps1` creates a local virtualenv, installs dependencies, and starts the server.
It will:

1. ask you to set a **password** (this is the one you type on the phone — min 8 chars),
2. print the **IP address(es)** to enter in the app,
3. listen on port **45813** (change it in `config.json`).

The first launch triggers a **Windows Firewall** prompt — allow access on
**Private networks**.

> Manual run without the launcher:
> ```powershell
> cd C:\SPECTER\server
> python -m pip install -r requirements.txt
> python specter_server.py
> ```

### Phone (client)

See **[ios/README.md](ios/README.md)** — create the Xcode project, add the Swift
files, sideload with your Apple ID. Then enter the PC's IP, the port and your password.

### Verify without the phone

Prove the server (crypto + capture + input) works using the bundled test client:

```powershell
cd C:\SPECTER
$env:SPECTER_PASSWORD="your-password"
python tools/test_client.py 127.0.0.1 45813 --move
```

It runs the real handshake, saves a captured frame to `tools/frame.png`, and nudges
the mouse. If that works, the phone will too.

---

## Configuration (`server/config.json`)

| key | meaning |
|---|---|
| `port` | TCP port to listen on (default 45813) |
| `monitor_index` | which monitor to share (1 = primary) |
| `tile` | tile size in px for delta encoding (128 is a good default) |
| `quality` / `target_fps` / `scale_pct` | default stream quality (phone can override live) |
| `received_dir` | where files sent *from the phone* land |
| `outbox_dir` | drop a file here and it is auto-offered *to the phone* |
| `allow_only_ip` | if set, only that one IP may connect |
| `idle_full_refresh_sec` | periodic full frame to self-heal (0 = off) |

## Project layout

```
C:\SPECTER
├─ server/            Windows Python server
│  ├─ specter_server.py   entry point / accept loop / dispatch
│  ├─ crypto.py           PBKDF2 + X25519 + HKDF + AES-GCM channel
│  ├─ protocol.py         frame types + encrypted framing
│  ├─ screen.py           capture + tile delta + JPEG
│  ├─ input_ctrl.py       mouse/keyboard injection (pynput)
│  ├─ clipboard.py        two-way clipboard sync
│  ├─ filetransfer.py     chunked file transfer + outbox watcher
│  ├─ config.py / config.json
│  └─ run.ps1 / requirements.txt
├─ ios/SPECTER/Sources/   SwiftUI client (add to an Xcode iOS App target)
├─ tools/test_client.py   headless smoke-test client
└─ docs/                  SECURITY.md, PROTOCOL.md
```

## Limitations / notes

- One phone connected at a time (by design — it's your personal link).
- LAN only by intent. To reach it from outside, put it behind a **WireGuard** tunnel
  rather than forwarding the port — see the note in `docs/SECURITY.md`.
- Screen streaming in pure Python tops out around real-time at 1080p–1440p on a normal
  desktop; use the *Fast* / *Data-saver* presets on weaker Wi-Fi.
