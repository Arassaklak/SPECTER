"""Two-way clipboard sync with echo suppression."""

import threading
import pyperclip


class ClipboardSync:
    def __init__(self, on_change):
        # on_change(text): called when the LOCAL clipboard changes, to push to client.
        self.on_change = on_change
        self._last = None
        self._suppress = None
        self._stop = threading.Event()
        self._thread = None

    def set_remote(self, text: str):
        """Apply text arriving from the client to the local clipboard."""
        self._suppress = text
        self._last = text
        try:
            pyperclip.copy(text)
        except Exception:
            pass

    def _loop(self):
        while not self._stop.is_set():
            try:
                cur = pyperclip.paste()
            except Exception:
                cur = None
            if cur and cur != self._last:
                self._last = cur
                if cur != self._suppress:
                    try:
                        self.on_change(cur)
                    except Exception:
                        pass
            self._stop.wait(0.7)

    def start(self):
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()
