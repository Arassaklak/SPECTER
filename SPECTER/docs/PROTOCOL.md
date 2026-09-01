# SPECTER — Wire protocol

All integers big-endian. After the handshake every message is:

```
[u32 length N][N bytes: u64 counter ‖ AES-256-GCM(ciphertext ‖ tag)]
```

The decrypted plaintext is `[u8 type][body…]`. Nonce = 4-byte per-direction prefix
(from the handshake) ‖ the 8-byte counter. Counters are strictly increasing per
direction; the receiver rejects any gap (replay/reorder protection).

## Handshake (cleartext, pre-channel)

| step | bytes |
|---|---|
| server → client | `"SPECTR"`(6) `ver`(1) `salt`(16) `s_nonce`(16) `s_eph_pub`(32) |
| client → server | `c_nonce`(16) `c_eph_pub`(32) `c_proof`(32) |
| server → client | `s_proof`(32) |

See [SECURITY.md](SECURITY.md) for the key schedule.

## Frame types

### Server → client
| type | name | body |
|---|---|---|
| 0x01 | SCREEN_INFO | u16 width, u16 height, u16 tile, u16 cols, u16 rows |
| 0x02 | SCREEN_TILE | u16 col, u16 row, u32 jpeg_len, jpeg bytes |
| 0x03 | SCREEN_FLUSH | — (end of this frame's changed tiles) |
| 0x20 | CLIPBOARD | utf-8 text |
| 0x30 | FILE_OFFER | u8 dir, u32 id, u64 size, u16 name_len, name |
| 0x31 | FILE_CHUNK | u32 id, u32 seq, bytes |
| 0x32 | FILE_DONE | u32 id, u8 ok |
| 0x41 | PONG | u64 token (echo) |
| 0x60 | MSG | utf-8 status text |

### Client → server
| type | name | body |
|---|---|---|
| 0x10 | MOUSE_MOVE | f32 x, f32 y (normalised 0..1) |
| 0x11 | MOUSE_BUTTON | f32 x, f32 y, u8 button(0=L,1=R,2=M), u8 down |
| 0x12 | MOUSE_SCROLL | f32 x, f32 y, i16 dx, i16 dy |
| 0x13 | KEY | u8 down, u16 keycode, u16 text_len, text utf-8 |
| 0x33 | FILE_ACCEPT | u32 id, u8 accept |
| 0x40 | PING | u64 token |
| 0x50 | SET_QUALITY | u8 quality(1..100), u8 fps(1..60), u8 scale_pct(10..100) |

Coordinates are normalised so the phone never needs the PC's real resolution; the
server maps them onto the captured monitor's pixel rectangle. Special keycodes are in
`server/input_ctrl.py::KEYMAP` and `ios/.../SpecterKeys.swift` (kept in sync).
