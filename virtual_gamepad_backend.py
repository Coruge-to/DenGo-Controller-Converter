# virtual_gamepad_backend.py
import gc
import time

_BUTTON_NAMES = {
    "dpad_up": "XUSB_GAMEPAD_DPAD_UP",
    "dpad_down": "XUSB_GAMEPAD_DPAD_DOWN",
    "dpad_left": "XUSB_GAMEPAD_DPAD_LEFT",
    "dpad_right": "XUSB_GAMEPAD_DPAD_RIGHT",
    "a": "XUSB_GAMEPAD_A",
    "b": "XUSB_GAMEPAD_B",
    "x": "XUSB_GAMEPAD_X",
    "y": "XUSB_GAMEPAD_Y",
    "start": "XUSB_GAMEPAD_START",
    "back": "XUSB_GAMEPAD_BACK",
}

class VirtualGamepadBackend:
    def __init__(self):
        self._vg = None
        self._pad = None
        self._pressed = set()

    @property
    def connected(self):
        return self._pad is not None

    def connect(self):
        if self.connected:
            return
        try:
            import vgamepad as vg
        except Exception as exc:
            detail = str(exc).strip()
            if "VIGEM_ERROR_BUS_NOT_FOUND" in detail:
                raise RuntimeError("VIGEM_ERROR_BUS_NOT_FOUND: ViGEmBus is not installed or is unavailable.") from exc
            if isinstance(exc, ImportError):
                raise RuntimeError("vgamepad is not installed.") from exc
            raise RuntimeError(f"Failed to import vgamepad: {detail or type(exc).__name__}") from exc
        try:
            pad = vg.VX360Gamepad()
            pad.reset()
            pad.update()
        except Exception as exc:
            detail = str(exc).strip()
            if "VIGEM_ERROR_BUS_NOT_FOUND" in detail:
                raise RuntimeError("VIGEM_ERROR_BUS_NOT_FOUND: ViGEmBus is not installed or is unavailable.") from exc
            raise RuntimeError(f"Failed to create a virtual Xbox 360 controller: {detail or type(exc).__name__}") from exc
        self._vg = vg
        self._pad = pad
        self._pressed.clear()
        print("VIRTUAL_GAMEPAD=CONNECTED", flush=True)

    def _button(self, name):
        if name not in _BUTTON_NAMES:
            raise ValueError(f"Unsupported virtual gamepad button: {name}")
        return getattr(self._vg.XUSB_BUTTON, _BUTTON_NAMES[name])

    def button_down(self, name):
        if not self.connected:
            raise RuntimeError("Virtual gamepad is not connected.")
        if name in self._pressed:
            return
        self._pad.press_button(button=self._button(name))
        self._pad.update()
        self._pressed.add(name)

    def button_up(self, name):
        if not self.connected or name not in self._pressed:
            return
        self._pad.release_button(button=self._button(name))
        self._pad.update()
        self._pressed.remove(name)

    def press(self, name, duration_seconds):
        self.button_down(name)
        try:
            time.sleep(max(0.0, float(duration_seconds)))
        finally:
            self.button_up(name)

    def neutralize(self):
        if self.connected:
            self._pad.reset()
            self._pad.update()
        self._pressed.clear()

    def disconnect(self):
        if not self.connected:
            return
        try:
            self.neutralize()
        finally:
            self._pad = None
            self._vg = None
            self._pressed.clear()
            gc.collect()
            print("VIRTUAL_GAMEPAD=DISCONNECTED", flush=True)
