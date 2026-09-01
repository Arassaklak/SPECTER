"""
SPECTER cryptographic core.

Design goals:
  * The user's password is NEVER transmitted. It is stretched with PBKDF2-HMAC-SHA256
    into a 32-byte master key on both sides.
  * Mutual authentication: each side proves knowledge of the master key with an HMAC
    over the full handshake transcript (prevents MITM / impersonation).
  * Forward secrecy: an ephemeral X25519 key exchange produces the session keys, so a
    password compromised *later* cannot decrypt *past* captured traffic.
  * Every application frame is AES-256-GCM sealed with a unique counter-based nonce,
    giving confidentiality, integrity and replay protection.

Handshake (server drives it):

  server -> client : MAGIC(6) VER(1) salt(16) s_nonce(16) s_eph_pub(32)
  client -> server : c_nonce(16) c_eph_pub(32) c_proof(32)
  server -> client : s_proof(32)

  transcript = salt || s_nonce || s_eph_pub || c_nonce || c_eph_pub
  master     = PBKDF2(password, salt)
  c_proof    = HMAC(master, transcript || "SPECTER-c2s")   # client authenticates
  s_proof    = HMAC(master, transcript || "SPECTER-s2c")   # server authenticates
  shared     = X25519(eph_priv, peer_eph_pub)
  session keys = HKDF(ikm=shared, salt=transcript, info=<label>)
"""

import os
import struct
import hmac as _hmac

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.hmac import HMAC
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)

MAGIC = b"SPECTR"          # 6 bytes
PROTO_VERSION = 1
PBKDF2_ITERATIONS = 210_000
SALT_LEN = 16
NONCE_LEN = 16             # handshake nonces
EPH_PUB_LEN = 32
PROOF_LEN = 32
KEY_LEN = 32              # AES-256
PREFIX_LEN = 4            # per-direction nonce prefix (4) + 8-byte counter = 12-byte GCM nonce


def derive_master_key(password: str, salt: bytes, iterations: int = PBKDF2_ITERATIONS) -> bytes:
    kdf = PBKDF2HMAC(algorithm=hashes.SHA256(), length=KEY_LEN, salt=salt, iterations=iterations)
    return kdf.derive(password.encode("utf-8"))


def _hkdf(ikm: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt, info=info).derive(ikm)


def _hmac_sha256(key: bytes, data: bytes) -> bytes:
    h = HMAC(key, hashes.SHA256())
    h.update(data)
    return h.finalize()


def _ct_eq(a: bytes, b: bytes) -> bool:
    return _hmac.compare_digest(a, b)


class HandshakeError(Exception):
    pass


class SecureChannel:
    """AES-256-GCM framing over an already-connected, authenticated socket.

    Nonce = 4-byte direction prefix || 8-byte big-endian counter (unique per frame).
    The counter is also written on the wire so the peer can detect gaps / replays.
    """

    def __init__(self, send_key: bytes, recv_key: bytes, send_prefix: bytes, recv_prefix: bytes):
        self._enc = AESGCM(send_key)
        self._dec = AESGCM(recv_key)
        self._send_prefix = send_prefix
        self._recv_prefix = recv_prefix
        self._send_ctr = 0
        self._recv_ctr = 0

    def seal(self, plaintext: bytes) -> bytes:
        ctr = self._send_ctr
        self._send_ctr += 1
        nonce = self._send_prefix + struct.pack(">Q", ctr)
        ct = self._enc.encrypt(nonce, plaintext, None)
        # wire: [ctr:8][ciphertext(+tag)]
        return struct.pack(">Q", ctr) + ct

    def open(self, wire: bytes) -> bytes:
        if len(wire) < 8:
            raise HandshakeError("short frame")
        ctr = struct.unpack(">Q", wire[:8])[0]
        if ctr != self._recv_ctr:
            raise HandshakeError(f"nonce/counter mismatch (replay?): got {ctr} want {self._recv_ctr}")
        self._recv_ctr += 1
        nonce = self._recv_prefix + wire[:8]
        return self._dec.decrypt(nonce, wire[8:], None)


# ---------------------------------------------------------------------------
# Handshake helpers
# ---------------------------------------------------------------------------

def _derive_channel_keys(shared: bytes, transcript: bytes):
    """Return (key_s2c, key_c2s, pre_s2c, pre_c2s)."""
    key_s2c = _hkdf(shared, transcript, b"specter/key/s2c", KEY_LEN)
    key_c2s = _hkdf(shared, transcript, b"specter/key/c2s", KEY_LEN)
    pre_s2c = _hkdf(shared, transcript, b"specter/pre/s2c", PREFIX_LEN)
    pre_c2s = _hkdf(shared, transcript, b"specter/pre/c2s", PREFIX_LEN)
    return key_s2c, key_c2s, pre_s2c, pre_c2s


def server_handshake(recv_exact, send_all, password: str) -> SecureChannel:
    """Perform the server side of the handshake.

    recv_exact(n) -> bytes (blocking, raises on EOF); send_all(bytes) -> None.
    Returns an established SecureChannel or raises HandshakeError.
    """
    salt = os.urandom(SALT_LEN)
    s_nonce = os.urandom(NONCE_LEN)
    s_eph = X25519PrivateKey.generate()
    s_eph_pub = s_eph.public_key().public_bytes_raw()

    send_all(MAGIC + bytes([PROTO_VERSION]) + salt + s_nonce + s_eph_pub)

    blob = recv_exact(NONCE_LEN + EPH_PUB_LEN + PROOF_LEN)
    c_nonce = blob[:NONCE_LEN]
    c_eph_pub = blob[NONCE_LEN:NONCE_LEN + EPH_PUB_LEN]
    c_proof = blob[NONCE_LEN + EPH_PUB_LEN:]

    transcript = salt + s_nonce + s_eph_pub + c_nonce + c_eph_pub
    master = derive_master_key(password, salt)

    expected = _hmac_sha256(master, transcript + b"SPECTER-c2s")
    if not _ct_eq(expected, c_proof):
        # Do not reveal *why* — just refuse. (Wrong password or an attacker.)
        raise HandshakeError("authentication failed (wrong password or tampering)")

    s_proof = _hmac_sha256(master, transcript + b"SPECTER-s2c")
    send_all(s_proof)

    shared = s_eph.exchange(X25519PublicKey.from_public_bytes(c_eph_pub))
    key_s2c, key_c2s, pre_s2c, pre_c2s = _derive_channel_keys(shared, transcript)
    return SecureChannel(send_key=key_s2c, recv_key=key_c2s, send_prefix=pre_s2c, recv_prefix=pre_c2s)


def client_handshake(recv_exact, send_all, password: str) -> SecureChannel:
    """Reference client handshake (used by the Python test client in tools/)."""
    header = recv_exact(6 + 1 + SALT_LEN + NONCE_LEN + EPH_PUB_LEN)
    if header[:6] != MAGIC:
        raise HandshakeError("bad magic (not a SPECTER server)")
    ver = header[6]
    if ver != PROTO_VERSION:
        raise HandshakeError(f"unsupported protocol version {ver}")
    off = 7
    salt = header[off:off + SALT_LEN]; off += SALT_LEN
    s_nonce = header[off:off + NONCE_LEN]; off += NONCE_LEN
    s_eph_pub = header[off:off + EPH_PUB_LEN]

    c_eph = X25519PrivateKey.generate()
    c_eph_pub = c_eph.public_key().public_bytes_raw()
    c_nonce = os.urandom(NONCE_LEN)

    transcript = salt + s_nonce + s_eph_pub + c_nonce + c_eph_pub
    master = derive_master_key(password, salt)
    c_proof = _hmac_sha256(master, transcript + b"SPECTER-c2s")

    send_all(c_nonce + c_eph_pub + c_proof)

    s_proof = recv_exact(PROOF_LEN)
    expected = _hmac_sha256(master, transcript + b"SPECTER-s2c")
    if not _ct_eq(expected, s_proof):
        raise HandshakeError("server authentication failed (wrong password or MITM)")

    shared = c_eph.exchange(X25519PublicKey.from_public_bytes(s_eph_pub))
    key_s2c, key_c2s, pre_s2c, pre_c2s = _derive_channel_keys(shared, transcript)
    # client sends c2s, receives s2c (mirror of the server)
    return SecureChannel(send_key=key_c2s, recv_key=key_s2c, send_prefix=pre_c2s, recv_prefix=pre_s2c)
