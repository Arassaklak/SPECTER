"""
SPECTER smoke-test client (no phone required).

    set SPECTER_PASSWORD=yourpass
    python tools/test_client.py 127.0.0.1 45813

Connects, runs the real handshake, receives one screen frame, saves it to
tools/frame.png, sends a ping, and (optionally) nudges the mouse to prove input
injection works. If this succeeds, the server stack is healthy.
"""

import io as _io
import os
import socket
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "server"))

import crypto  # noqa: E402
from protocol import (  # noqa: E402
    FrameIO, read_exact,
    T_SCREEN_INFO, T_SCREEN_TILE, T_SCREEN_FLUSH, T_PING, T_PONG, T_MSG,
    T_SET_QUALITY, T_MOUSE_MOVE, T_CLIPBOARD,
)
from PIL import Image  # noqa: E402


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 45813
    password = os.environ.get("SPECTER_PASSWORD") or input("password: ")
    move_mouse = "--move" in sys.argv

    sock = socket.create_connection((host, port), timeout=10)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    channel = crypto.client_handshake(lambda n: read_exact(sock, n), sock.sendall, password)
    print("[ok] handshake succeeded — encryption + auth working")
    conn = FrameIO(sock, channel)

    conn.send(T_SET_QUALITY, struct.pack(">BBB", 60, 15, 100))
    conn.send(T_PING, struct.pack(">Q", 0xC0FFEE))

    canvas = None
    tile = 128
    got_flush = False
    t0 = time.time()
    while time.time() - t0 < 15:
        ftype, body = conn.recv()
        if ftype == T_SCREEN_INFO:
            w, h, tile, cols, rows = struct.unpack(">HHHHH", body)
            canvas = Image.new("RGB", (w, h))
            print(f"[info] screen {w}x{h}, tile={tile}, grid {cols}x{rows}")
        elif ftype == T_SCREEN_TILE and canvas is not None:
            col, row, jlen = struct.unpack(">HHI", body[:8])
            jpeg = body[8:8 + jlen]
            canvas.paste(Image.open(_io.BytesIO(jpeg)), (col * tile, row * tile))
        elif ftype == T_SCREEN_FLUSH:
            got_flush = True
            if canvas is not None:
                out = os.path.join(HERE, "frame.png")
                canvas.save(out)
                print(f"[ok] saved a full frame -> {out}")
                break
        elif ftype == T_PONG:
            print(f"[ok] pong token={struct.unpack('>Q', body)[0]:#x}")
        elif ftype == T_MSG:
            print(f"[server] {body.decode('utf-8', 'replace')}")
        elif ftype == T_CLIPBOARD:
            print(f"[clip] {body.decode('utf-8','replace')[:80]!r}")

    if move_mouse:
        # move the pointer to the screen centre to prove input injection
        conn.send(T_MOUSE_MOVE, struct.pack(">ff", 0.5, 0.5))
        print("[ok] sent mouse-move to centre")

    if not got_flush:
        print("[warn] no complete frame within timeout")
    conn.close()


if __name__ == "__main__":
    main()
