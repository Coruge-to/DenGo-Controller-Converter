import pygame
import pydirectinput
import time
import os
import sys

# --- 設定 ---
pydirectinput.PAUSE = 0
CONFIRM_WAIT_TIME = 0.02
N_WAIT_TIME = 0.10
KEY_REPEAT_DELAY = 0.01

# --- キーアサイン ---
KEY_MASCON_UP, KEY_MASCON_DOWN, KEY_MASCON_N = 'z', 'a', 's'
KEY_BRAKE_N, KEY_BRAKE_UP, KEY_BRAKE_DOWN, KEY_BRAKE_EMG = 'm', '.', ',', '/'
KEY_START, KEY_SELECT = 'backspace', 'enter'

# --- 初期化 ---
pygame.init()
pygame.joystick.init()
if pygame.joystick.get_count() == 0:
    print("コントローラーが見つかりません。")
    time.sleep(3)
    sys.exit()
joy = pygame.joystick.Joystick(0); joy.init()

# --- 定数マップ ---
ELECTRIC_BRAKE_MAP = {14: 0, 13: 1, 12: 2, 11: 3, 10: 4, 9: 5, 8: 6, 7: 7, 6: 8, 0: 9}
AUTO_BRAKE_MAP = {
    14: 0, 13: 0, 12: 0, 11: 0, 10: 0, 9: 0, 8: 0, 7: 0,
    6:  6,
    5:  8, 4: 8, 3: 8, 2: 8, 1: 8,
    0:  9
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
        if raw_val == -1: return self.confirmed
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

# --- ユーティリティ: 自動空気ブレーキの状態名 ---
def get_auto_brake_str(val):
    if val == 9: return "非常"
    if val == 6: return "重なり"
    if val == 8: return "常用"
    return "運転" # 0

# --- メイン処理 ---
try:
    os.system('cls' if os.name == 'nt' else 'clear')
    print("=========================================")
    print("    JRETS Controller Converter v1.1      ")
    print("=========================================")
    print("1: 電気指令式 (211系，E233系など)")
    print("2: 自動空気ブレーキ (キハ54，185系など)")
    print("-----------------------------------------")
    
    mode_input = input("モードを選択 [1/2] (Default: 1): ").strip()
    mode = "2" if mode_input == "2" else "1"

    # --- 設定入力 (Enter連打でデフォルト適用) ---
    print("\n[ 車両設定 (Enterでデフォルト値を適用) ]")
    
    # 力行設定
    p_in = input("最大力行ノッチ [1-5] (Default: 5): ").strip()
    MAX_POWER = int(p_in) if p_in.isdigit() and 1 <= int(p_in) <= 5 else 5
    
    # ブレーキ設定 (電気指令式のみ)
    MAX_BRAKE = 8
    if mode == "1":
        b_in = input("最大ブレーキノッチ [1-8] (Default: 8): ").strip()
        MAX_BRAKE = int(b_in) if b_in.isdigit() and 1 <= int(b_in) <= 8 else 8
        print(f"\n>> 設定: Mode 1 (電気指令式) | P:{MAX_POWER} / B:{MAX_BRAKE}")
    else:
        print(f"\n>> 設定: Mode 2 (自動空気)   | P:{MAX_POWER}")

    print("\n準備完了。コントローラーを認識中...")
    time.sleep(1)

    # 初期同期
    b_val, p_pat, _ = get_inputs()
    init_p = MASCON_LEVEL_MAP.get(p_pat, 0); init_p = 0 if init_p == -1 else init_p
    init_b = ELECTRIC_BRAKE_MAP.get(b_val, 0) if mode == "1" else 0
    
    # 初期値クランプ・マッピング
    init_p = min(init_p, MAX_POWER)
    if mode == "1":
        if init_b == 9: init_b = MAX_BRAKE + 1
        elif init_b > 0: init_b = min(init_b, MAX_BRAKE)

    mascon_filter = StableNotchReader(init_p)
    brake_filter = StableNotchReader(init_b)

    prev_p, prev_b = init_p, init_b
    last_auto_s = 0
    p_start, p_select = False, False

    while True:
        b_val, p_pat, btns = get_inputs()

        # 入力変換
        if mode == "1": raw_b = ELECTRIC_BRAKE_MAP.get(b_val, -1)
        else: raw_b = AUTO_BRAKE_MAP.get(b_val, -1)
        raw_p = MASCON_LEVEL_MAP.get(p_pat, -1)
        
        # フィルタリング
        filtered_b = brake_filter.update(raw_b)
        filtered_p = mascon_filter.update(raw_p)

        # --- クランプ処理 (修正版) ---
        cur_p = min(filtered_p, MAX_POWER) # 力行は共通で頭打ち
        
        # ブレーキ論理値の計算
        if mode == "1":
            if filtered_b == 9: 
                # 【重要】非常位置は「最大段数 + 1」として扱う
                # これにより、最大B7設定でも 非常(8) - 最大(7) = 1 となり、計算が合う
                cur_b = MAX_BRAKE + 1
            elif filtered_b == 0:
                cur_b = 0
            else:
                # 常用は最大段数で頭打ち
                cur_b = min(filtered_b, MAX_BRAKE)
        else:
            cur_b = filtered_b

        # --- HUD (UI表示) ---
        os.system('cls' if os.name == 'nt' else 'clear')
        print(f"=========================================")
        print(f"  MODE: {'電気指令式' if mode=='1' else '自動空気ブレーキ'}")
        print(f"=========================================")
        
        # マスコン表示
        p_bar = "|" * cur_p + "." * (MAX_POWER - cur_p)
        print(f" マスコン : P{cur_p} [{p_bar}]")
        
        # ブレーキ表示
        if mode == "1":
            # 表示用ロジック
            if cur_b == MAX_BRAKE + 1: # 非常
                b_str = "非常(EB)"
                b_bar = "!!!!!!!!!"
            elif cur_b == 0: 
                b_str = "緩解(N)"
                b_bar = "|" * 0 + "." * MAX_BRAKE
            else: 
                b_str = f"B{cur_b}"
                b_bar = "|" * cur_b + "." * (MAX_BRAKE - cur_b)
            
            print(f" ブレーキ : {b_str:<10} [{b_bar}]")
        else:
            # 自動空気ブレーキ用表示
            auto_str = get_auto_brake_str(cur_b)
            print(f" ブレーキ : {auto_str}")

        print(f"-----------------------------------------")
        print(f" Raw Val  : P_PAT={p_pat} / B_VAL={b_val:04b}")
        print(f" Ctrl+C で終了")

        # --- 出力ロジック (Order Fix版準拠) ---

        # 1. ブレーキ立ち上がり -> マスコン強制解除
        if prev_b == 0 and cur_b > 0:
            pydirectinput.press(KEY_MASCON_N)
            time.sleep(KEY_REPEAT_DELAY)
            prev_p = 0

        # 2. ブレーキ出力
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
                # 非常判定 (MAX_BRAKE + 1 かどうかで判定)
                is_emergency = (cur_b == MAX_BRAKE + 1)
                
                if is_emergency: 
                    pydirectinput.keyDown(KEY_BRAKE_EMG)
                else:
                    pydirectinput.keyUp(KEY_BRAKE_EMG)
                    if cur_b == 0: 
                        pydirectinput.press(KEY_BRAKE_N)
                    else:
                        diff = cur_b - prev_b
                        for _ in range(abs(diff)):
                            pydirectinput.press(KEY_BRAKE_UP if diff > 0 else KEY_BRAKE_DOWN)
                            time.sleep(KEY_REPEAT_DELAY)

        # 3. マスコン出力
        if cur_b > 0:
            prev_p = 0
        else:
            if cur_p != prev_p:
                if cur_p == 0:
                    pydirectinput.press(KEY_MASCON_N)
                else:
                    diff = cur_p - prev_p
                    for _ in range(abs(diff)):
                        pydirectinput.press(KEY_MASCON_UP if diff > 0 else KEY_MASCON_DOWN)
                        time.sleep(KEY_REPEAT_DELAY)
                prev_p = cur_p

        prev_b = cur_b

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