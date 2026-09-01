"""
Screen capture with tile-based delta encoding.

The framebuffer is divided into a grid of square tiles. Each frame we compare
every tile against the previous frame and only JPEG-encode + send the tiles that
changed. On a mostly-static desktop this drops bandwidth by 10-100x, which is
what makes it feel fast over Wi-Fi.

NOTE: create the ScreenCapturer inside the thread that will call capture() —
mss is not designed to be shared across threads.
"""

import io
import mss
import numpy as np
from PIL import Image


class ScreenCapturer:
    def __init__(self, monitor_index: int = 1, tile: int = 128, quality: int = 70, scale_pct: int = 100):
        self.tile = tile
        self.quality = max(1, min(100, quality))
        self.scale_pct = max(10, min(100, scale_pct))
        self._sct = mss.mss()
        mons = self._sct.monitors
        # monitors[0] is the "all monitors" virtual screen; 1..N are physical.
        self.monitor_index = monitor_index if monitor_index < len(mons) else 1
        self._mon = mons[self.monitor_index]
        self._prev = None

    def set_params(self, quality=None, scale_pct=None):
        if quality:
            self.quality = max(1, min(100, quality))
        if scale_pct:
            new = max(10, min(100, scale_pct))
            if new != self.scale_pct:
                self.scale_pct = new
                self._prev = None  # geometry changed -> force a full refresh

    def _grab(self) -> np.ndarray:
        raw = self._sct.grab(self._mon)
        img = np.frombuffer(raw.rgb, dtype=np.uint8).reshape(raw.height, raw.width, 3)
        if self.scale_pct != 100:
            w = max(1, raw.width * self.scale_pct // 100)
            h = max(1, raw.height * self.scale_pct // 100)
            img = np.asarray(Image.fromarray(img).resize((w, h), Image.BILINEAR))
        return np.ascontiguousarray(img)

    def _encode(self, tile_img: np.ndarray) -> bytes:
        buf = io.BytesIO()
        Image.fromarray(tile_img).save(buf, format="JPEG", quality=self.quality)
        return buf.getvalue()

    def capture(self):
        """Return (width, height, tile, cols, rows, changed_tiles, full_refresh).

        changed_tiles is a list of (col, row, jpeg_bytes).
        """
        img = self._grab()
        h, w, _ = img.shape
        t = self.tile
        cols = (w + t - 1) // t
        rows = (h + t - 1) // t
        full = self._prev is None or self._prev.shape != img.shape
        changed = []
        for r in range(rows):
            y0, y1 = r * t, min(r * t + t, h)
            for c in range(cols):
                x0, x1 = c * t, min(c * t + t, w)
                tile_img = img[y0:y1, x0:x1]
                if not full and np.array_equal(tile_img, self._prev[y0:y1, x0:x1]):
                    continue
                changed.append((c, r, self._encode(np.ascontiguousarray(tile_img))))
        self._prev = img
        return w, h, t, cols, rows, changed, full
