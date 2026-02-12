import pygame
import os

# 初期化
pygame.init()
pygame.joystick.init()

if pygame.joystick.get_count() == 0:
    print("コントローラーが接続されていません。")
    exit()

joy = pygame.joystick.Joystick(0)
joy.init()

# --- 定数定義 (Excel準拠) ---
# ビットパターン: [N4(btn6), N3(btn8), N2(btn5), N1(btn7)]
NOTCH_NAME_MAP = {
    14: "N",      # 1110
    13: "B1",            # 1101
    12: "B2",            # 1100
    11: "B3",            # 1011
    10: "B4",            # 1010
    9:  "B5",            # 1001
    8:  "B6",            # 1000
    7:  "B7",            # 0111
    6:  "B8",            # 0110 (重なり)
    
    # --- 無段階領域 (常用) ---
    15: "常用 (奇数段: B9...)", # 1111
    5:  "常用 (B10)",    # 0101
    4:  "常用 (B12)",    # 0100
    3:  "常用 (B14)",    # 0011
    2:  "常用 (B16)",    # 0010
    1:  "常用 (B18)",    # 0001
    
    0:  "非常",          # 0000
}

# --- 関数定義 ---
def get_raw_input():
    pygame.event.pump()
    # 0-15の入力を取得した後、先頭にNoneを入れて1-16にする
    raw_btns = [joy.get_button(i) for i in range(16)]
    btns = [None] + raw_btns 
    
    # Excelの番号そのまま使用: [btn6, btn8, btn5, btn7]
    b_pattern = [btns[6], btns[8], btns[5], btns[7]]
    
    b_val = 0
    for bit in b_pattern:
        b_val = (b_val << 1) | bit
        
    return btns, b_val

def get_mascon_state(btns):
    # Excel番号: M3(14), M2(16), M1(1)
    p_pattern = (btns[14], btns[16], btns[1])
    p_map = {
        (1, 1, 0): "切 (N)",
        (1, 0, 1): "力行 1",
        (1, 0, 0): "力行 2",
        (0, 1, 1): "力行 3",
        (0, 1, 0): "力行 4",
        (0, 0, 1): "力行 5"
    }
    return p_map.get(p_pattern, "不明")

def get_other_buttons(btns):
    # Excel番号: START(9), SELECT(10) ※ここもExcel通りか要確認
    # 直近の修正依頼に基づき、Python idx8=Start, idx9=Select だったので
    # Excel番号に直すと: idx8 -> btn9 (START), idx9 -> btn10 (SELECT) となります
    pressed = []
    if btns[9] == 1: pressed.append("START")
    if btns[10] == 1: pressed.append("SELECT")
    return " / ".join(pressed) if pressed else "-"

# --- メイン処理 ---
try:
    print("=== コントローラー動作モード選択 ===")
    print("1: 電気指令式 (N, B1...B8表示 / B9以降はB8扱い)")
    print("2: 自動空気ブレーキ (運転, 重なり, 常用, 非常 表示)")
    mode = input("モードを入力してください (1 or 2): ")

    while True:
        btns, b_val = get_raw_input()
        mascon_str = get_mascon_state(btns)
        btn_str = get_other_buttons(btns)
        
        # --- モード別表示ロジック ---
        
        if mode == "1":
            # [モード1] 電気指令式
            
            # 特例: 無段階領域(常用)の値が来たら、すべて「B8」として扱う
            if b_val in [15, 5, 4, 3, 2, 1]:
                main_status = "B8"
            else:
                main_status = NOTCH_NAME_MAP.get(b_val, f"不明 ({b_val})")
                
            display_title = "【電気指令式モード】"

        else:
            # [モード2] 自動空気ブレーキ
            display_title = "【自動空気ブレーキモード】"
            
            if b_val == 0:
                main_status = "非常"
            
            elif b_val == 6: # B8 = 0110
                main_status = "重なり"
            
            elif b_val == 14: # N = 1110
                main_status = "運転"
            
            elif 7 <= b_val <= 13: # B1(13) ～ B7(7)
                main_status = "運転"
            
            elif b_val in [15, 5, 4, 3, 2, 1]: 
                main_status = "常用"
            
            else:
                main_status = f"不明 ({b_val})"

        # --- 画面描画 ---
        os.system('cls' if os.name == 'nt' else 'clear')
        print(display_title)
        print(f"マスコン : {mascon_str}")
        print(f"ブレーキ : {main_status}")
        print(f"ボタン   : {btn_str}")
        print("-" * 40)
        print(f"内部数値 : {b_val:2d} (2進: {b_val:04b})")
        
        pygame.time.wait(50)

except KeyboardInterrupt:
    print("\n終了します。")