"""Configuration loading. The password is deliberately NOT stored on disk."""

import json
import os

DEFAULTS = {
    "host": "0.0.0.0",       # listen on all interfaces (LAN). Use a specific IP to pin it.
    "port": 45813,
    "monitor_index": 1,       # 1 = primary; 2.. = other monitors
    "tile": 128,
    "quality": 70,            # JPEG quality 1..100
    "target_fps": 30,
    "scale_pct": 100,         # downscale factor for bandwidth (10..100)
    "received_dir": "C:/SPECTER/received",   # files sent phone -> PC land here
    "outbox_dir": "C:/SPECTER/outbox",       # drop files here to auto-send PC -> phone
    "sent_dir": "C:/SPECTER/outbox/_sent",
    "allow_only_ip": "",      # optional: reject any client whose IP != this
    "idle_full_refresh_sec": 3  # periodic full frame to heal any lost tiles
}


def load(path: str = None) -> dict:
    cfg = dict(DEFAULTS)
    path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")
    if os.path.isfile(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                cfg.update(json.load(f))
        except Exception as e:
            print(f"[config] ignoring bad config.json: {e}")
    return cfg


def get_password() -> str:
    """Prefer interactive prompt; fall back to SPECTER_PASSWORD env for headless runs."""
    env = os.environ.get("SPECTER_PASSWORD")
    if env:
        return env
    import getpass
    while True:
        pw = getpass.getpass("SPECTER password (the one you'll type on the phone): ")
        if len(pw) >= 8:
            return pw
        print("  Please use at least 8 characters.")
