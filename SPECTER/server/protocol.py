"""
SPECTER wire protocol.

After the handshake, every message on the socket is:

    [4-byte big-endian length N][N bytes of SecureChannel.seal(payload)]

The sealed payload's plaintext is:

    [1-byte frame type][frame body...]

Frame bodies are defined per-type below. Multi-byte integers are big-endian.
Screen coordinates from the client are normalised floats in [0.0, 1.0] so the
phone never needs to know the PC's real resolution.
"""

import struct
import threading

# ---- Frame types -----------------------------------------------------------
# Server -> Client
T_SCREEN_INFO   = 0x01   # u16 width, u16 height, u16 tile, u16 cols, u16 rows
T_SCREEN_TILE   = 0x02   # u16 col, u16 row, u32 jpeg_len, jpeg bytes   (one changed tile)
T_SCREEN_FLUSH  = 0x03   # (empty) marks end of a frame's batch of tiles
T_PONG          = 0x41   # echo of ping token (u64)
T_CLIPBOARD     = 0x20   # utf-8 text (both directions)
T_FILE_OFFER    = 0x30   # u8 dir, u32 id, u64 size, u16 name_len, name utf-8
T_FILE_CHUNK    = 0x31   # u32 id, u32 seq, bytes
T_FILE_DONE     = 0x32   # u32 id, u8 ok
T_MSG           = 0x60   # utf-8 status/toast text server -> client

# Client -> Server
T_MOUSE_MOVE    = 0x10   # f32 x, f32 y            (normalised)
T_MOUSE_BUTTON  = 0x11   # f32 x, f32 y, u8 button(0=L,1=R,2=M), u8 down
T_MOUSE_SCROLL  = 0x12   # f32 x, f32 y, i16 dx, i16 dy
T_KEY           = 0x13   # u8 down, u16 keycode, u16 text_len, text utf-8
T_PING          = 0x40   # u64 token
T_SET_QUALITY   = 0x50   # u8 jpeg_quality(1..100), u8 target_fps(1..60), u8 scale_pct(10..100)
T_FILE_ACCEPT   = 0x33   # u32 id, u8 accept

# button ids
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0, 1, 2
# file directions
FILE_TO_CLIENT, FILE_TO_SERVER = 0, 1


def read_exact(sock, n: int) -> bytes:
    """Read exactly n bytes or raise ConnectionError on EOF."""
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed connection")
        buf.extend(chunk)
    return bytes(buf)


class FrameIO:
    """Encrypted, framed, thread-safe I/O over one socket + SecureChannel."""

    MAX_FRAME = 32 * 1024 * 1024  # 32 MiB hard cap (defensive)

    def __init__(self, sock, channel):
        self._sock = sock
        self._chan = channel
        self._send_lock = threading.Lock()
        self._recv_lock = threading.Lock()

    def send(self, ftype: int, body: bytes = b"") -> None:
        plaintext = bytes([ftype]) + body
        with self._send_lock:
            sealed = self._chan.seal(plaintext)          # seal() mutates the counter -> must be locked
            self._sock.sendall(struct.pack(">I", len(sealed)) + sealed)

    def recv(self):
        """Return (ftype, body). Blocking. Raises on EOF/tamper."""
        with self._recv_lock:
            (n,) = struct.unpack(">I", read_exact(self._sock, 4))
            if n > self.MAX_FRAME or n < 8:
                raise ConnectionError(f"illegal frame length {n}")
            wire = read_exact(self._sock, n)
            plaintext = self._chan.open(wire)             # verifies GCM tag + counter
        if not plaintext:
            raise ConnectionError("empty plaintext frame")
        return plaintext[0], plaintext[1:]

    def close(self):
        try:
            self._sock.shutdown(2)
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass


# ---- Small body (de)serialisers -------------------------------------------

def pack_screen_info(width, height, tile, cols, rows):
    return struct.pack(">HHHHH", width, height, tile, cols, rows)

def pack_screen_tile(col, row, jpeg: bytes):
    return struct.pack(">HHI", col, row, len(jpeg)) + jpeg

def unpack_mouse_move(body):
    return struct.unpack(">ff", body)                     # x, y

def unpack_mouse_button(body):
    x, y, btn, down = struct.unpack(">ffBB", body)
    return x, y, btn, down

def unpack_mouse_scroll(body):
    x, y, dx, dy = struct.unpack(">ffhh", body)
    return x, y, dx, dy

def unpack_key(body):
    down, keycode, tlen = struct.unpack(">BHH", body[:5])
    text = body[5:5 + tlen].decode("utf-8", "replace")
    return down, keycode, text

def unpack_set_quality(body):
    q, fps, scale = struct.unpack(">BBB", body)
    return q, fps, scale
