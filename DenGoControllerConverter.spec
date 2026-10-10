# -*- mode: python ; coding: utf-8 -*-

from importlib.metadata import distribution
from pathlib import Path

vgamepad_root = Path(distribution('vgamepad').locate_file('vgamepad')).resolve()
vigem_client_x64 = vgamepad_root / 'win' / 'vigem' / 'client' / 'x64' / 'ViGEmClient.dll'
if not vigem_client_x64.is_file():
    raise FileNotFoundError(str(vigem_client_x64))

a = Analysis(
    ['main.py'],
    pathex=[],
    binaries=[
        (str(vigem_client_x64), 'vgamepad/win/vigem/client/x64'),
    ],
    datas=[('DenGo-Controller-Converter.ico', '.')],
    hiddenimports=['vgamepad'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', 'tcl', 'numpy', 'matplotlib', 'PIL'],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)
exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.datas,
    [],
    name='DenGoControllerConverter',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=['DenGo-Controller-Converter.ico'],
    version='DenGoControllerConverter-version.txt',
)
