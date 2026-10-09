from __future__ import annotations
import ctypes
import time
from dataclasses import dataclass
from ctypes import wintypes

if not hasattr(ctypes, 'windll'):
    raise RuntimeError('This module requires Windows.')

user32 = ctypes.windll.user32
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_NULL = 0x0000
SMTO_ABORTIFHUNG = 0x0002
ULONG_PTR = ctypes.c_size_t
KEY_NAMES = {
    'backspace': 0x08, 'enter': 0x0D, 'space': 0x20,
    'left': 0x25, 'up': 0x26, 'right': 0x27, 'down': 0x28,
    '.': 0xBE, ',': 0xBC, ';': 0xBA, '/': 0xBF, 'add': 0x6B,
}

@dataclass(frozen=True)
class WindowTarget:
    platform_id: str
    pid: int
    hwnd: int
    class_name: str
    title: str

def parse_key(value: str) -> int:
    lowered = value.lower()
    if lowered.startswith('0x'):
        return int(lowered, 16)
    if lowered in KEY_NAMES:
        return KEY_NAMES[lowered]
    if len(value) == 1 and value.isalpha():
        return ord(value.upper())
    if len(value) == 1 and value.isdigit():
        return ord(value)
    raise ValueError(f'Unsupported key: {value}')

user32.IsWindow.argtypes = [wintypes.HWND]
user32.IsWindow.restype = wintypes.BOOL
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowVisible.restype = wintypes.BOOL
user32.MapVirtualKeyW.argtypes = [wintypes.UINT, wintypes.UINT]
user32.MapVirtualKeyW.restype = wintypes.UINT
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
user32.PostMessageW.restype = wintypes.BOOL
user32.SendMessageTimeoutW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM, wintypes.UINT, wintypes.UINT, ctypes.POINTER(ULONG_PTR)]
user32.SendMessageTimeoutW.restype = ULONG_PTR

def _lparam(vk: int, key_up: bool) -> int:
    scan = int(user32.MapVirtualKeyW(vk, 0)) & 0xFF
    value = 1 | (scan << 16)
    if key_up:
        value |= (1 << 30) | (1 << 31)
    return value

class WindowMessageBackend:
    def __init__(self) -> None:
        self._target = None
        self._pressed = set()

    @property
    def target(self):
        return self._target

    def attach(self, target: WindowTarget) -> None:
        self.detach()
        if not user32.IsWindow(target.hwnd) or not user32.IsWindowVisible(target.hwnd):
            raise RuntimeError('Target window is no longer valid and visible.')
        self._target = target

    def _require_target(self) -> WindowTarget:
        if self._target is None or not user32.IsWindow(self._target.hwnd):
            self._pressed.clear()
            self._target = None
            raise RuntimeError('No valid target window is attached.')
        return self._target

    def ping(self, timeout_ms: int = 500) -> bool:
        target = self._require_target()
        result = ULONG_PTR()
        return bool(user32.SendMessageTimeoutW(target.hwnd, WM_NULL, 0, 0, SMTO_ABORTIFHUNG, timeout_ms, ctypes.byref(result)))

    def key_down(self, key) -> None:
        vk = parse_key(key) if isinstance(key, str) else int(key)
        target = self._require_target()
        if vk in self._pressed:
            return
        if not user32.PostMessageW(target.hwnd, WM_KEYDOWN, vk, _lparam(vk, False)):
            raise ctypes.WinError(ctypes.get_last_error())
        self._pressed.add(vk)

    def key_up(self, key) -> None:
        vk = parse_key(key) if isinstance(key, str) else int(key)
        target = self._target
        if target is None:
            self._pressed.discard(vk)
            return
        if not user32.IsWindow(target.hwnd):
            self._pressed.discard(vk)
            self._target = None
            return
        if not user32.PostMessageW(target.hwnd, WM_KEYUP, vk, _lparam(vk, True)):
            raise ctypes.WinError(ctypes.get_last_error())
        self._pressed.discard(vk)

    def press(self, key, hold_seconds: float = 0.06) -> None:
        self.key_down(key)
        try:
            time.sleep(max(0.0, float(hold_seconds)))
        finally:
            self.key_up(key)

    def release_all(self) -> None:
        target = self._target
        if target is not None and user32.IsWindow(target.hwnd):
            for vk in tuple(self._pressed):
                user32.PostMessageW(target.hwnd, WM_KEYUP, vk, _lparam(vk, True))
        self._pressed.clear()

    def detach(self) -> None:
        self.release_all()
        self._target = None
