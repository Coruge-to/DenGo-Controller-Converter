# const.py
import pygame

# ★PCSX2/RPCS3モード専用設定 (秒)
PCSX2_PRESS_DURATION = 0.04
PCSX2_RELEASE_DURATION = 0.04
PCSX2_RESET_WAIT = 0.05

FPS = 60

# --- 画面設定 ---
SCREEN_WIDTH = 800
SCREEN_HEIGHT = 600
MARGIN_SIDE = 100

# --- 色定義 (RGB) ---
COLOR_BG = (30, 30, 30)
COLOR_HEADER_BG = (40, 40, 40)
COLOR_TEXT = (230, 230, 230)
COLOR_TEXT_DIM = (160, 160, 160)
COLOR_ACCENT = (0, 200, 255) # 水色

COLOR_N = (0, 180, 80)      # JRETSモード色 / Nランプ色
COLOR_P = (0, 120, 220)     # PCSX2モード色 / Pランプ色
COLOR_B_SVC = (220, 120, 0) # BVEモード色 / 常用ブレーキランプ色
COLOR_B_EMG = (200, 20, 20)
COLOR_MIDOSUJI = (229, 23, 31) # 御堂筋モード色

# ★AE100モードの色設定
COLOR_AE100_TXT = (0, 80, 180)   # 文字色 (青)
COLOR_AE100_FRAME = (255, 250, 240) # 枠色 (赤)
COLOR_AE100_BTN = (148, 0, 211)   # ボタン色 (紫)

# ★787系モード色
COLOR_787_TXT = (210, 210, 210) # 明るめの銀色（文字用）
COLOR_787_BTN = (120, 120, 120) # 銀色（ボタン用）

# ★RPCS3モード色
COLOR_RPCS3_BTN = (148, 0, 211) # ボタンは紫

# ★京阪8000系モードの色設定
COLOR_KEIHAN_RED  = (180, 30, 40)  # ← 枠・背景の色 (京阪レッド)
COLOR_KEIHAN_GOLD = (235, 190, 0)  # ← 文字の色 (ゴールド)

# ★その他
COLOR_NORMAL_BTN = (60, 80, 100) # 通常ボタン色
COLOR_OFF_FILL = (45, 45, 45)
COLOR_HANDLE_BRASS = (180, 150, 60)
COLOR_HANDLE_WOOD = (100, 60, 30)
COLOR_HOLE = (20, 20, 20)

# --- キーアサイン (JRETS/BVE) ---
KEY_MASCON_UP, KEY_MASCON_DOWN, KEY_MASCON_N = 'z', 'a', 's'
KEY_BRAKE_N, KEY_BRAKE_UP, KEY_BRAKE_DOWN, KEY_BRAKE_EMG = 'm', '.', ',', '/'
KEY_START, KEY_SELECT, KEY_START_BVE = 'backspace', 'enter',  'add'


# --- キーアサイン (PCSX2/RPCS3) ---
KEY_PCSX2_POWER_INC = 'z' # マスコン増 / ハンドル奥へ
KEY_PCSX2_POWER_DEC = 'q' # マスコン減 / ハンドル手前へ
KEY_PCSX2_BRAKE_INC = '.' # ツーハン ブレーキ増 (通常)
KEY_PCSX2_BRAKE_DEC = ',' # ツーハン ブレーキ減 (通常)
KEY_PCSX2_N         = 's' # マスコン切 (N) ショートカット
KEY_PCSX2_EMG       = '/' # 非常ブレーキ (PCSX2専用)
KEY_PCSX2_HORN1     = 'enter'     # SELECT
KEY_PCSX2_HORN2     = 'backspace' # START

# --- 定数マップ ---
# 電気指令式 => 構成 : 緩解, 常用13段, 非常
ELECTRIC_BRAKE_MAP = {
    14: 0,   # N  (1110)
    13: 1,   # B1 (1101)
    12: 2,   # B2 (1100)
    11: 3,   # B3 (1011)
    10: 4,   # B4 (1010)
    9: 5,    # B5 (1001)
    8: 6,    # B6 (1000)
    7: 7,    # B7 (0111)
    6: 8,    # B8 (0110)
    5: 9,    # B9 (0101)  <- ここから無段階
    4: 10,   # B10 (0100)
    3: 11,   # B11 (0011)
    2: 12,   # B12 (0010)
    1: 13,   # B13 (0001)
    0: 14    # EB (0000)
}

# 自動空気ブレーキ 構成 : 運転, 重なり, 常用, 非常
AUTO_BRAKE_MAP = {
    14: 0, 13: 0, 12: 0, 11: 0, 10: 0, 9: 0, 8: 0, 7: 0,    # 運転
    6:  1,                                                  # 重なり
    5:  2, 4: 2, 3: 2, 2: 2, 1: 2,                          # 常用
    0:  3                                                   # 非常
}

# マスコン(共通) 構成 : N, 5段
MASCON_LEVEL_MAP = {
    (1, 1, 0): 0, # N
    (1, 0, 1): 1, # P1
    (1, 0, 0): 2, # P2
    (0, 1, 1): 3, # P3
    (0, 1, 0): 4, # P4
    (0, 0, 1): 5  # P5
}