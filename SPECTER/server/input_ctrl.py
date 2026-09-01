"""
Mouse + keyboard injection via pynput.

Coordinates arrive normalised (0..1) relative to the captured monitor, so we map
them onto that monitor's real pixel rectangle (supporting non-primary monitors
via the left/top offset).

Keyboard: the client sends discrete down/up events. Printable characters arrive
as `text`; special keys (arrows, enter, modifiers, F-keys...) arrive as a
`keycode` from the shared table below. Sending modifier down, letter down/up,
modifier up reproduces combos such as Ctrl+C or Alt+Tab.
"""

from pynput.mouse import Controller as MouseController, Button
from pynput.keyboard import Controller as KeyController, Key

BTN = {0: Button.left, 1: Button.right, 2: Button.middle}

# keycode table — must stay in sync with the iOS client (SpecterKeys.swift)
KEYMAP = {
    1: Key.enter, 2: Key.backspace, 3: Key.tab, 4: Key.esc, 5: Key.space,
    6: Key.up, 7: Key.down, 8: Key.left, 9: Key.right,
    10: Key.delete, 11: Key.home, 12: Key.end, 13: Key.page_up, 14: Key.page_down,
    20: Key.ctrl, 21: Key.shift, 22: Key.alt, 23: Key.cmd,
    24: Key.ctrl_r, 25: Key.shift_r, 26: Key.alt_r,
    42: Key.caps_lock, 43: Key.insert, 44: Key.menu, 45: Key.print_screen,
}
for i in range(1, 13):  # F1..F12 -> 30..41
    KEYMAP[29 + i] = getattr(Key, f"f{i}")


class InputController:
    def __init__(self, get_geometry):
        """get_geometry() -> dict with keys left, top, width, height (captured monitor)."""
        self._mouse = MouseController()
        self._kb = KeyController()
        self._geo = get_geometry

    def _to_px(self, x: float, y: float):
        g = self._geo()
        x = min(max(x, 0.0), 1.0)
        y = min(max(y, 0.0), 1.0)
        return int(g["left"] + x * g["width"]), int(g["top"] + y * g["height"])

    def move(self, x, y):
        self._mouse.position = self._to_px(x, y)

    def button(self, x, y, btn, down):
        self._mouse.position = self._to_px(x, y)
        b = BTN.get(btn, Button.left)
        if down:
            self._mouse.press(b)
        else:
            self._mouse.release(b)

    def scroll(self, x, y, dx, dy):
        self._mouse.position = self._to_px(x, y)
        self._mouse.scroll(dx, dy)

    def key(self, down, keycode, text):
        try:
            if keycode:
                k = KEYMAP.get(keycode)
                if k is None:
                    return
                self._kb.press(k) if down else self._kb.release(k)
            elif text:
                # Character keys arrive as a down/up pair. We emit the glyph on the
                # DOWN edge via type(), which applies the right shifting for capitals
                # and symbols and still combines with any modifier currently held
                # (e.g. Ctrl held + 'c' -> Ctrl+C). The UP edge is a no-op.
                if down:
                    self._kb.type(text)
        except Exception:
            # An unmappable key should never take the session down.
            pass
