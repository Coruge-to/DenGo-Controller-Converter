import pygame
import pydirectinput
import time
import os

# --- 設定 ---
pydirectinput.PAUSE = 0
CONFIRM_WAIT_TIME = 0.02 # 通常判定ウェイト (爆速)
N_WAIT_TIME = 0.10       # N判定ウェイト (慎重)
KEY_REPEAT_DELAY = 0.01 # キー連打間隔 (爆速)

# --- キーアサイン ---
KEY_MASCON_UP, KEY_MASCON_DOWN, KEY_MASCON_N = 'z', 'a', 's'
KEY_BRAKE_N, KEY_BRAKE_UP, KEY_BRAKE_DOWN, KEY_BRAKE_EMG = 'm', '.', ',', '/'
KEY_START, KEY_SELECT = 'backspace', 'enter'

# --- 初期化 ---
pygame.init()
pygame.joystick.init()
if pygame.joystick.get_count() == 0:
    print("コントローラーが見つかりません。")
    exit()
joy = pygame.joystick.Joystick(0); joy.init()

# --- 定数マップ ---
ELECTRIC_BRAKE_MAP = {14: 0, 13: 1, 12: 2, 11: 3, 10: 4, 9: 5, 8: 6, 7: 7, 6: 8, 0: 9}

# 自動空気: 15 (全ビット開放) はマップから削除 -> ノイズとして無視される
AUTO_BRAKE_MAP = {
    14: 0, 13: 0, 12: 0, 11: 0, 10: 0, 9: 0, 8: 0, 7: 0, # 運転
    6:  6, # 重なり
    5:  8, 4: 8, 3: 8, 2: 8, 1: 8, # 常用 (偶数番地などの有効な値のみ)
    0:  9  # 非常
}

MASCON_LEVEL_MAP = {
    (1, 1, 0): 0, # N
    (1, 0, 1): 1, # P1
    (1, 0, 0): 2, # P2
    (0, 1, 1): 3, # P3
    (0, 1, 0): 4, # P4
    (0, 0, 1): 5  # P5
}

# --- フィルタクラス ---
class StableNotchReader:
    def __init__(self, init_val=0):
        self.last_raw = init_val
        self.start_time = time.time()
        self.confirmed = init_val

    def update(self, raw_val):
        now = time.time()
        # マップ外(-1)は徹底無視 -> 前回値を維持
        if raw_val == -1: return self.confirmed
        
        # N(0)への変化だけ慎重に
        limit = N_WAIT_TIME if raw_val == 0 else CONFIRM_WAIT_TIME
        
        if raw_val != self.last_raw:
            self.start_time = now; self.last_raw = raw_val
            return self.confirmed
        
        if (now - self.start_time) > limit:
            self.confirmed = raw_val; return raw_val
        return self.confirmed

# --- 入力取得 ---
def get_inputs():
    pygame.event.pump()
    raw = [joy.get_button(i) for i in range(16)]
    btns = [None] + raw 
    b_val = (btns[6]<<3) | (btns[8]<<2) | (btns[5]<<1) | btns[7]
    p_pat = (btns[14], btns[16], btns[1])
    return b_val, p_pat, btns

# --- メイン処理 ---
try:
    os.system('cls' if os.name == 'nt' else 'clear')
    print("=== JRETS コントローラー (The Final Simple) ===")
    mode = input("モードを選択 (1:電気指令, 2:自動空気): ").strip()

    # 初期同期
    b_val, p_pat, _ = get_inputs()
    init_p = MASCON_LEVEL_MAP.get(p_pat, 0); init_p = 0 if init_p == -1 else init_p
    init_b = ELECTRIC_BRAKE_MAP.get(b_val, 0) if mode == "1" else 0
    
    mascon_filter = StableNotchReader(init_p)
    brake_filter = StableNotchReader(init_b)

    prev_p, prev_b = init_p, init_b
    last_auto_s = 0
    p_start, p_select = False, False

    print(f"\n初期化: P{init_p}, B{init_b} | 制御開始...")

    while True:
        b_val, p_pat, btns = get_inputs()

        # --- 入力ロジック (超シンプル化) ---
        if mode == "1":
            raw_b = ELECTRIC_BRAKE_MAP.get(b_val, -1)
        else:
            # 自動空気でも get() 一発！ 15等のノイズは -1 になり無視される
            raw_b = AUTO_BRAKE_MAP.get(b_val, -1)

        raw_p = MASCON_LEVEL_MAP.get(p_pat, -1)
        
        # フィルタ適用
        cur_b = brake_filter.update(raw_b)
        cur_p = mascon_filter.update(raw_p)

        # --- HUD ---
        os.system('cls' if os.name == 'nt' else 'clear')
        print(f"マスコン: P{cur_p} | ブレーキ: B{cur_b if cur_b<9 else 'Emg'} (物理:{b_val:04b})")

        # --- 出力: ブレーキ ---
        if mode == "2":
            new_s = 3 if cur_b==9 else (1 if cur_b==6 else (2 if cur_b==8 else 0))
            if new_s != last_auto_s:
                pydirectinput.keyUp(KEY_BRAKE_N); pydirectinput.keyUp(KEY_BRAKE_UP); pydirectinput.keyUp(KEY_BRAKE_EMG)
                if new_s == 0: pydirectinput.keyDown(KEY_BRAKE_N)
                elif new_s == 1:
                    if last_auto_s == 0: pydirectinput.press(KEY_BRAKE_UP)
                elif new_s == 2: pydirectinput.keyDown(KEY_BRAKE_UP)
                elif new_s == 3: pydirectinput.keyDown(KEY_BRAKE_EMG)
                last_auto_s = new_s
        else:
            if cur_b != prev_b:
                if cur_b == 9: pydirectinput.keyDown(KEY_BRAKE_EMG)
                else:
                    pydirectinput.keyUp(KEY_BRAKE_EMG)
                    if cur_b == 0: pydirectinput.press(KEY_BRAKE_N)
                    else:
                        diff = cur_b - prev_b
                        for _ in range(abs(diff)):
                            pydirectinput.press(KEY_BRAKE_UP if diff > 0 else KEY_BRAKE_DOWN)
                            time.sleep(KEY_REPEAT_DELAY)
                prev_b = cur_b

        # --- 出力: マスコン ---
        if cur_p != prev_p:
            if cur_b == 0: 
                if cur_p == 0:
                    pydirectinput.press(KEY_MASCON_N)
                else:
                    diff = cur_p - prev_p
                    for _ in range(abs(diff)):
                        pydirectinput.press(KEY_MASCON_UP if diff > 0 else KEY_MASCON_DOWN)
                        time.sleep(KEY_REPEAT_DELAY)
            prev_p = cur_p

        # ボタン
        is_start, is_select = (btns[9]==1), (btns[10]==1)
        if is_start != p_start:
            pydirectinput.keyDown(KEY_START) if is_start else pydirectinput.keyUp(KEY_START)
            p_start = is_start
        if is_select != p_select:
            pydirectinput.keyDown(KEY_SELECT) if is_select else pydirectinput.keyUp(KEY_SELECT)
            p_select = is_select

        time.sleep(0.005)

except KeyboardInterrupt:
    print("\n終了")