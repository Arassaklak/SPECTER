"""
Chunked, encrypted file transfer (rides the same encrypted FrameIO as everything else).

phone -> PC : client sends T_FILE_OFFER(dir=TO_SERVER) then T_FILE_CHUNK.. then T_FILE_DONE.
              Files land in received_dir.
PC -> phone : drop a file into outbox_dir. The watcher offers it; once the client
              accepts (T_FILE_ACCEPT), we stream chunks, then move the file to sent_dir.
"""

import os
import struct
import threading
import time

from protocol import (
    T_FILE_OFFER, T_FILE_CHUNK, T_FILE_DONE,
    FILE_TO_CLIENT, FILE_TO_SERVER,
)

CHUNK = 64 * 1024


class FileHub:
    def __init__(self, io, received_dir, outbox_dir, sent_dir):
        self.io = io
        self.received_dir = received_dir
        self.outbox_dir = outbox_dir
        self.sent_dir = sent_dir
        for d in (received_dir, outbox_dir, sent_dir):
            os.makedirs(d, exist_ok=True)
        self._incoming = {}
        self._accepts = {}
        self._next_id = 1
        self._lock = threading.Lock()
        self._stop = threading.Event()

    # -------- incoming (phone -> PC) --------
    def on_offer(self, body):
        direction = body[0]
        _id, size = struct.unpack(">IQ", body[1:13])
        (nlen,) = struct.unpack(">H", body[13:15])
        name = body[15:15 + nlen].decode("utf-8", "replace")
        if direction != FILE_TO_SERVER:
            return
        safe = os.path.basename(name).replace("\\", "_").replace("/", "_")
        path = os.path.join(self.received_dir, safe or f"file_{_id}")
        try:
            self._incoming[_id] = {"f": open(path, "wb"), "path": path, "size": size}
            print(f"[file] receiving '{safe}' ({size} bytes) -> {path}")
        except OSError as e:
            print(f"[file] cannot open {path}: {e}")

    def on_chunk(self, body):
        _id, _seq = struct.unpack(">II", body[:8])
        rec = self._incoming.get(_id)
        if rec:
            rec["f"].write(body[8:])

    def on_done(self, body):
        _id, _ok = struct.unpack(">IB", body[:5])
        rec = self._incoming.pop(_id, None)
        if rec:
            rec["f"].close()
            print(f"[file] completed {rec['path']}")

    def on_accept(self, body):
        _id, accept = struct.unpack(">IB", body[:5])
        ev = self._accepts.get(_id)
        if ev:
            ev["ok"] = bool(accept)
            ev["evt"].set()

    # -------- outgoing (PC -> phone) --------
    def _send_file(self, path) -> bool:
        with self._lock:
            _id = self._next_id
            self._next_id += 1
        size = os.path.getsize(path)
        name = os.path.basename(path).encode("utf-8")
        self.io.send(T_FILE_OFFER, bytes([FILE_TO_CLIENT]) + struct.pack(">IQH", _id, size, len(name)) + name)
        ev = {"evt": threading.Event(), "ok": False}
        self._accepts[_id] = ev
        try:
            if not ev["evt"].wait(30) or not ev["ok"]:
                print(f"[file] client declined/timeout for {path}")
                return False
        finally:
            self._accepts.pop(_id, None)
        seq = 0
        with open(path, "rb") as f:
            while True:
                data = f.read(CHUNK)
                if not data:
                    break
                self.io.send(T_FILE_CHUNK, struct.pack(">II", _id, seq) + data)
                seq += 1
        self.io.send(T_FILE_DONE, struct.pack(">IB", _id, 1))
        print(f"[file] sent {path} -> phone")
        return True

    def _watch_outbox(self):
        seen = set()
        while not self._stop.is_set():
            try:
                for name in os.listdir(self.outbox_dir):
                    path = os.path.join(self.outbox_dir, name)
                    if name.startswith("_") or not os.path.isfile(path) or path in seen:
                        continue
                    seen.add(path)
                    if self._send_file(path):
                        try:
                            os.replace(path, os.path.join(self.sent_dir, name))
                        except OSError:
                            pass
                        seen.discard(path)
            except Exception as e:
                print(f"[file] outbox watcher error: {e}")
            self._stop.wait(1.0)

    def start_outbox_watcher(self):
        threading.Thread(target=self._watch_outbox, daemon=True).start()

    def stop(self):
        self._stop.set()
        for rec in list(self._incoming.values()):
            try:
                rec["f"].close()
            except OSError:
                pass
        self._incoming.clear()
