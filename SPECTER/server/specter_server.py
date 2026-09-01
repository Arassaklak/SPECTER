"""
SPECTER server (Windows).

    python specter_server.py

Listens on the LAN, performs the authenticated + forward-secret handshake, then
streams the screen and accepts input / clipboard / file frames from one phone at
a time. Ctrl+C to quit.
"""

import socket
import struct
import sys
import threading
import time

import mss

import config
import crypto
from protocol import (
    FrameIO, read_exact, pack_screen_info, pack_screen_tile,
    T_SCREEN_INFO, T_SCREEN_TILE, T_SCREEN_FLUSH,
    T_MOUSE_MOVE, T_MOUSE_BUTTON, T_MOUSE_SCROLL, T_KEY,
    T_PING, T_PONG, T_CLIPBOARD, T_SET_QUALITY, T_MSG,
    T_FILE_OFFER, T_FILE_CHUNK, T_FILE_DONE, T_FILE_ACCEPT,
    unpack_mouse_move, unpack_mouse_button, unpack_mouse_scroll,
    unpack_key, unpack_set_quality,
)
from screen import ScreenCapturer
from input_ctrl import InputController
from clipboard import ClipboardSync
from filetransfer import FileHub


class Settings:
    def __init__(self, cfg):
        self.quality = cfg["quality"]
        self.fps = cfg["target_fps"]
        self.scale = cfg["scale_pct"]
        self.dirty = False


def local_ips():
    ips = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None):
            addr = info[4][0]
            if "." in addr and not addr.startswith("127."):
                ips.add(addr)
    except socket.gaierror:
        pass
    # Robust fallback: which local IP would reach the internet / LAN gateway.
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ips.add(s.getsockname()[0])
        s.close()
    except OSError:
        pass
    return sorted(ips)


def monitor_geometry(index):
    with mss.mss() as sct:
        mons = sct.monitors
        m = mons[index if index < len(mons) else 1]
        return {"left": m["left"], "top": m["top"], "width": m["width"], "height": m["height"]}


def screen_loop(io, cfg, settings, stop_evt):
    cap = ScreenCapturer(cfg["monitor_index"], cfg["tile"], settings.quality, settings.scale)
    last_full = 0.0
    last_info = None
    idle_full = cfg.get("idle_full_refresh_sec", 0)
    try:
        while not stop_evt.is_set():
            start = time.time()
            if settings.dirty:
                cap.set_params(quality=settings.quality, scale_pct=settings.scale)
                settings.dirty = False
            if idle_full and (start - last_full) >= idle_full:
                cap._prev = None  # force a full frame to self-heal
            w, h, t, cols, rows, changed, full = cap.capture()
            if full:
                last_full = start
            info = (w, h, t, cols, rows)
            if info != last_info:
                io.send(T_SCREEN_INFO, pack_screen_info(*info))
                last_info = info
            for c, r, jpeg in changed:
                io.send(T_SCREEN_TILE, pack_screen_tile(c, r, jpeg))
            if changed:
                io.send(T_SCREEN_FLUSH)
            target = 1.0 / max(1, settings.fps)
            elapsed = time.time() - start
            if elapsed < target:
                stop_evt.wait(target - elapsed)
    except (ConnectionError, OSError) as e:
        print(f"[screen] link closed: {e}")
    finally:
        stop_evt.set()


def serve_client(sock, addr, cfg, password):
    print(f"[+] client connected from {addr[0]}:{addr[1]}")
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def recv_exact(n):
        return read_exact(sock, n)

    def send_all(b):
        sock.sendall(b)

    try:
        channel = crypto.server_handshake(recv_exact, send_all, password)
    except Exception as e:
        print(f"[!] handshake rejected for {addr[0]}: {e}")
        try:
            sock.close()
        except OSError:
            pass
        return
    print(f"[+] {addr[0]} authenticated — session established")

    io = FrameIO(sock, channel)
    stop_evt = threading.Event()
    settings = Settings(cfg)
    geo = monitor_geometry(cfg["monitor_index"])
    inp = InputController(lambda: geo)

    clip = ClipboardSync(on_change=lambda text: _safe(io.send, T_CLIPBOARD, text.encode("utf-8")))
    clip.start()
    files = FileHub(io, cfg["received_dir"], cfg["outbox_dir"], cfg["sent_dir"])
    files.start_outbox_watcher()

    io.send(T_MSG, "SPECTER connected".encode("utf-8"))
    threading.Thread(target=screen_loop, args=(io, cfg, settings, stop_evt), daemon=True).start()

    try:
        while not stop_evt.is_set():
            ftype, body = io.recv()
            if ftype == T_MOUSE_MOVE:
                inp.move(*unpack_mouse_move(body))
            elif ftype == T_MOUSE_BUTTON:
                inp.button(*unpack_mouse_button(body))
            elif ftype == T_MOUSE_SCROLL:
                inp.scroll(*unpack_mouse_scroll(body))
            elif ftype == T_KEY:
                inp.key(*unpack_key(body))
            elif ftype == T_PING:
                io.send(T_PONG, body)
            elif ftype == T_CLIPBOARD:
                clip.set_remote(body.decode("utf-8", "replace"))
            elif ftype == T_SET_QUALITY:
                q, fps, scale = unpack_set_quality(body)
                settings.quality, settings.fps, settings.scale = q, fps, scale
                settings.dirty = True
                print(f"[cfg] quality={q} fps={fps} scale={scale}%")
            elif ftype == T_FILE_OFFER:
                files.on_offer(body)
            elif ftype == T_FILE_CHUNK:
                files.on_chunk(body)
            elif ftype == T_FILE_DONE:
                files.on_done(body)
            elif ftype == T_FILE_ACCEPT:
                files.on_accept(body)
            else:
                print(f"[?] unknown frame type 0x{ftype:02x}")
    except (ConnectionError, OSError) as e:
        print(f"[-] client {addr[0]} disconnected: {e}")
    except Exception as e:
        print(f"[!] session error: {e}")
    finally:
        stop_evt.set()
        clip.stop()
        files.stop()
        io.close()
        print(f"[-] session with {addr[0]} closed")


def _safe(fn, *a):
    try:
        fn(*a)
    except Exception:
        pass


def main():
    cfg = config.load()
    password = config.get_password()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((cfg["host"], cfg["port"]))
    srv.listen(1)

    print("=" * 60)
    print(" SPECTER server is listening")
    print(f"   port      : {cfg['port']}")
    print(f"   monitor   : {cfg['monitor_index']}")
    print("   put ONE of these IPs into the iPhone app:")
    for ip in local_ips():
        print(f"       {ip}:{cfg['port']}")
    print("   received files -> ", cfg["received_dir"])
    print("   drop files to send in -> ", cfg["outbox_dir"])
    print("=" * 60)

    try:
        while True:
            sock, addr = srv.accept()
            if cfg.get("allow_only_ip") and addr[0] != cfg["allow_only_ip"]:
                print(f"[!] refused {addr[0]} (allow_only_ip={cfg['allow_only_ip']})")
                sock.close()
                continue
            # one client at a time — handle inline; extra connections wait in the backlog
            serve_client(sock, addr, cfg, password)
    except KeyboardInterrupt:
        print("\n[x] shutting down")
    finally:
        srv.close()


if __name__ == "__main__":
    main()
