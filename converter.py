import pygame
import pydirectinput
import time
import sys
import math

# --- 設定 ---
pydirectinput.PAUSE = 0
CONFIRM_WAIT_TIME = 0.02
N_WAIT_TIME = 0.10
KEY_REPEAT_DELAY = 0.01

# --- 画面設定 ---
SCREEN_WIDTH = 800
SCREEN_HEIGHT = 600
FPS = 60
MARGIN_SIDE = 100       # 画面端からのマージン

# --- 色定義 (RGB) ---
COLOR_BG = (30, 30, 30)         # 背景
COLOR_HEADER_BG = (40, 40, 40)  # ヘッダー背景
COLOR_TEXT = (230, 230, 230)    # 白文字
COLOR_TEXT_DIM = (160, 160, 160)# 薄い文字（ラベル用）
COLOR_ACCENT = (0, 200, 255)    # アクセント(水色)

# インジケーター色
COLOR_N = (0, 180, 80)          # N：濃い緑
COLOR_P = (0, 120, 220)         # P：濃い青
COLOR_B_SVC = (220, 120, 0)     # 常用：オレンジ
COLOR_B_EMG = (200, 20, 20)     # 非常：赤
COLOR_OFF_FILL = (45, 45, 45)   # 消灯時の塗り
COLOR_HANDLE_BRASS = (180, 150, 60)  # ハンドル真鍮色
COLOR_HANDLE_WOOD = (100, 60, 30)    # ハンドル持ち手(木)
COLOR_HOLE = (20, 20, 20)       # 軸の穴

# --- キーアサイン ---
KEY_MASCON_UP, KEY_MASCON_DOWN, KEY_MASCON_N = 'z', 'a', 's'
KEY_BRAKE_N, KEY_BRAKE_UP, KEY_BRAKE_DOWN, KEY_BRAKE_EMG = 'm', '.', ',', '/'
KEY_START, KEY_SELECT = 'backspace', 'enter'

# --- 初期化 ---
pygame.init()
pygame.display.set_caption("JRETS Controller Converter v3.0") 
screen = pygame.display.set_mode((SCREEN_WIDTH, SCREEN_HEIGHT))
clock = pygame.time.Clock()

# フォント読み込み
font_ui_label = pygame.font.SysFont("meiryo", 18, bold=True)
font_ui_bold = pygame.font.SysFont("meiryo", 20, bold=True)
font_header_title = pygame.font.SysFont("meiryo", 26, bold=True)
font_val = pygame.font.SysFont("meiryo", 32, bold=True)
font_gauge = pygame.font.SysFont("meiryo", 24, bold=True)
font_gauge_s = pygame.font.SysFont("meiryo", 20, bold=True)
font_arrow = pygame.font.SysFont("meiryo", 16, bold=True)

# ジョイスティック
pygame.joystick.init()
if pygame.joystick.get_count() == 0:
    print("コントローラーが見つかりません。")
    # time.sleep(3); sys.exit()
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

# --- クラス・関数定義 ---

def draw_solid_arc(surface, color, center, r_inner, r_outer, start_deg, end_deg):
    """
    円弧を「多角形」として計算して塗りつぶす関数。
    draw.arcの重ね塗りではないため、隙間ができません。
    """
    points = []
    cx, cy = center
    step = 0.5  # 精度(度単位)。小さいほど滑らか
    
    # 1. 外側の円弧の点列を計算
    angle = start_deg
    while angle <= end_deg:
        rad = math.radians(angle)
        # Y軸は下向き正なので、通常の数学座標(Y上向き)のsinを反転させるロジックに合わせる
        # 元コード: ly = center[1] - r * sin(theta) 
        x = cx + r_outer * math.cos(rad)
        y = cy - r_outer * math.sin(rad)
        points.append((x, y))
        angle += step
    # 最後の点を確実に追加
    rad_end = math.radians(end_deg)
    points.append((cx + r_outer * math.cos(rad_end), cy - r_outer * math.sin(rad_end)))

    # 2. 内側の円弧の点列を計算（逆順に追加することで閉じた図形にする）
    angle = end_deg
    while angle >= start_deg:
        rad = math.radians(angle)
        x = cx + r_inner * math.cos(rad)
        y = cy - r_inner * math.sin(rad)
        points.append((x, y))
        angle -= step
    # 最初の点(内側)を確実に追加
    rad_start = math.radians(start_deg)
    points.append((cx + r_inner * math.cos(rad_start), cy - r_inner * math.sin(rad_start)))
    
    # 多角形として描画
    pygame.draw.polygon(surface, color, points)


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

class Button:
    def __init__(self, x, y, w, h, text, callback, color=(60,60,60), font=font_ui_bold):
        self.rect = pygame.Rect(x, y, w, h)
        self.text = text
        self.callback = callback
        self.base_color = color
        self.font = font
        self.hover = False

    def draw(self, surface):
        col = (min(self.base_color[0]+30, 255), min(self.base_color[1]+30, 255), min(self.base_color[2]+30, 255)) if self.hover else self.base_color
        pygame.draw.rect(surface, col, self.rect, border_radius=4)
        pygame.draw.rect(surface, (100, 100, 100), self.rect, 1, border_radius=4)
        
        txt_surf = self.font.render(self.text, True, COLOR_TEXT)
        surface.blit(txt_surf, (self.rect.centerx - txt_surf.get_width()//2, self.rect.centery - txt_surf.get_height()//2))

    def handle_event(self, event):
        if event.type == pygame.MOUSEMOTION:
            self.hover = self.rect.collidepoint(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN:
            if self.hover and event.button == 1:
                self.callback()

# --- 入力取得 ---
def get_inputs():
    pygame.event.pump()
    raw = [joy.get_button(i) for i in range(16)]
    btns = [None] + raw 
    b_val = (btns[6]<<3) | (btns[8]<<2) | (btns[5]<<1) | btns[7]
    p_pat = (btns[14], btns[16], btns[1])
    return b_val, p_pat, btns

# --- 描画関数 ---

def draw_bar_gauge(surface, center_x, start_y, current_val, max_val, is_mascon):
    width = 100
    box_h = 34
    spacing = 6
    x = center_x - width // 2 
    
    # N (切)
    n_rect = pygame.Rect(x, start_y, width, box_h)
    is_n_active = (current_val == 0)
    
    if is_n_active:
        pygame.draw.rect(surface, COLOR_N, n_rect, border_radius=3)
        txt_col = (255, 255, 255)
    else:
        pygame.draw.rect(surface, COLOR_OFF_FILL, n_rect, border_radius=3)
        pygame.draw.rect(surface, COLOR_N, n_rect, 1, border_radius=3)
        txt_col = COLOR_TEXT

    label = font_gauge.render("N", True, txt_col)
    surface.blit(label, (n_rect.centerx - label.get_width()//2, n_rect.centery - label.get_height()//2))

    # 各段
    current_y = start_y + box_h + spacing

    for i in range(1, max_val + 1):
        r = pygame.Rect(x, current_y, width, box_h)
        
        # 点灯ロジック
        if is_mascon:
            is_active = (current_val >= i)
        else:
            is_active = (current_val >= i) and (current_val <= max_val)
        
        base_color = COLOR_P if is_mascon else COLOR_B_SVC
        
        if is_active:
            pygame.draw.rect(surface, base_color, r, border_radius=3)
            txt_col_val = (255, 255, 255)
        else:
            pygame.draw.rect(surface, COLOR_OFF_FILL, r, border_radius=3)
            pygame.draw.rect(surface, base_color, r, 1, border_radius=3)
            txt_col_val = COLOR_TEXT

        txt = f"P{i}" if is_mascon else f"B{i}"
        ren = font_gauge.render(txt, True, txt_col_val)
        surface.blit(ren, (r.centerx - ren.get_width()//2, r.centery - ren.get_height()//2))
        
        current_y += box_h + spacing

    # EB (ブレーキのみ)
    if not is_mascon:
        eb_rect = pygame.Rect(x, current_y, width, box_h)
        is_eb_active = (current_val == max_val + 1)
        
        if is_eb_active:
            pygame.draw.rect(surface, COLOR_B_EMG, eb_rect, border_radius=3)
            txt_col_val = (255, 255, 255)
        else:
            pygame.draw.rect(surface, COLOR_OFF_FILL, eb_rect, border_radius=3)
            pygame.draw.rect(surface, COLOR_B_EMG, eb_rect, 1, border_radius=3)
            txt_col_val = COLOR_TEXT
            
        ren = font_gauge.render("EB", True, txt_col_val)
        surface.blit(ren, (eb_rect.centerx - ren.get_width()//2, eb_rect.centery - ren.get_height()//2))


def draw_auto_brake_unit(surface, center_x, center_y, current_val):
    center = (center_x, center_y)
    label_radius = 180  
    
    # --- 円弧の描画 (完全修正版: ポリゴン描画) ---
    
    arc_width = 15
    # 内径・外径
    r_inner = label_radius - (arc_width // 2)
    r_outer = label_radius + (arc_width // 2)

    # 色の決定
    col_arc_run = COLOR_N if current_val == 0 else COLOR_OFF_FILL
    col_arc_brk = COLOR_B_SVC if current_val == 8 else COLOR_OFF_FILL

    # 接続部オーバーラップ角
    overlap_angle = 10 

    # --- 運転～重なり間 (緑) ---
    # 範囲: 200度 ～ 270度 (+オーバーラップ)
    draw_solid_arc(surface, col_arc_run, center, r_inner, r_outer, 
                   200, 270 + overlap_angle)

    # --- 重なり～常用～非常間 (橙) ---
    # 範囲: 270度(-オーバーラップ) ～ 380度
    draw_solid_arc(surface, col_arc_brk, center, r_inner, r_outer, 
                   270 - overlap_angle, 380)


    # --- 以下、インジケーター(円)とハンドルの描画 ---
    angles = { 0: 200, 6: 270, 8: 330, 9: 20 }
    target_angle = angles.get(current_val, 200)

    # ラベル配置
    labels = [
        (0, "運転", 200, COLOR_N),
        (6, "重なり", 270, COLOR_B_SVC),
        (8, "常用", 330, COLOR_B_SVC),
        (9, "非常", 20, COLOR_B_EMG)
    ]
    
    for val, text, ang, act_color in labels:
        lx = center[0] + label_radius * math.cos(math.radians(ang))
        ly = center[1] - label_radius * math.sin(math.radians(ang))
        
        is_active = (current_val == val)
        
        if is_active:
                pygame.draw.circle(surface, act_color, (int(lx), int(ly)), 40)
                txt_col = (255, 255, 255)
        else:
                pygame.draw.circle(surface, COLOR_OFF_FILL, (int(lx), int(ly)), 40)
                pygame.draw.circle(surface, act_color, (int(lx), int(ly)), 40, 2)
                txt_col = COLOR_TEXT

        ren = font_gauge_s.render(text, True, txt_col)
        surface.blit(ren, (lx - ren.get_width()//2, ly - ren.get_height()//2))

    # --- ハンドル描画 ---
    angle_rad = math.radians(-target_angle)
    
    brass_len = 35
    wood_len = 100
    grip_w = 28
    line_width = 16
    
    arm_offset_perp = 0.6
    ox = arm_offset_perp * math.sin(angle_rad)
    oy = -arm_offset_perp * math.cos(angle_rad)

    overlap_len = brass_len + 30
    arm_start = (center[0], center[1])
    arm_end_x = center[0] + overlap_len * math.cos(angle_rad)
    arm_end_y = center[1] + overlap_len * math.sin(angle_rad)
    pygame.draw.line(surface, COLOR_HANDLE_BRASS, arm_start, (arm_end_x, arm_end_y), line_width)
    
    grip_center_dist = brass_len + wood_len / 2
    grip_center_x = center[0] + grip_center_dist * math.cos(angle_rad) + ox
    grip_center_y = center[1] + grip_center_dist * math.sin(angle_rad) + oy
    
    grip_surf = pygame.Surface((wood_len, grip_w), pygame.SRCALPHA)
    
    poly_points = [
        (0, grip_w//2 - 10),          
        (wood_len - 15, grip_w//2 - 14),
        (wood_len - 15, grip_w//2 + 14),
        (0, grip_w//2 + 10)            
    ]
    pygame.draw.polygon(grip_surf, COLOR_HANDLE_WOOD, poly_points)
    pygame.draw.circle(grip_surf, COLOR_HANDLE_WOOD, (wood_len - 15, grip_w//2), 14)
    
    rotated_grip = pygame.transform.rotate(grip_surf, target_angle)
    grip_rect = rotated_grip.get_rect(center=(grip_center_x, grip_center_y))
    surface.blit(rotated_grip, grip_rect)

    pygame.draw.circle(surface, COLOR_HANDLE_BRASS, center, 16)
    
    hole_size = 14
    hole_surf = pygame.Surface((hole_size, hole_size), pygame.SRCALPHA)
    hole_surf.fill(COLOR_HOLE)
    rotated_hole = pygame.transform.rotate(hole_surf, target_angle)
    hole_rect = rotated_hole.get_rect(center=center)
    surface.blit(rotated_hole, hole_rect)


# --- グローバル設定変数 ---
current_mode = "1"
max_power = 5
max_brake = 8

def toggle_mode():
    global current_mode
    current_mode = "2" if current_mode == "1" else "1"

def inc_p(): global max_power; max_power = min(5, max_power + 1)
def dec_p(): global max_power; max_power = max(1, max_power - 1)
def inc_b(): global max_brake; max_brake = min(8, max_brake + 1)
def dec_b(): global max_brake; max_brake = max(1, max_brake - 1)

# --- メインループ ---
def main():
    b_val, p_pat, _ = get_inputs()
    init_p = MASCON_LEVEL_MAP.get(p_pat, 0); init_p = 0 if init_p == -1 else init_p
    init_b = ELECTRIC_BRAKE_MAP.get(b_val, 0)
    
    mascon_filter = StableNotchReader(init_p)
    brake_filter = StableNotchReader(init_b)
    
    prev_p, prev_b = init_p, init_b
    last_auto_s = 0
    p_start, p_select = False, False

    # レイアウト計算
    mascon_center_x = MARGIN_SIDE + 50 
    elec_brake_center_x = SCREEN_WIDTH - MARGIN_SIDE - 50
    
    auto_r_circle = 40
    auto_label_radius = 180
    auto_brake_center_x = (SCREEN_WIDTH - MARGIN_SIDE) - auto_r_circle - (auto_label_radius * math.cos(math.radians(20)))
    auto_brake_center_y = 250

    # Y座標
    header_h = 70        
    label_y = 90         
    val_y = 120          
    gauge_start_y = 180 
    
    # ボタン
    btns = [
        Button(20, (header_h - 40)//2, 140, 40, "モード切替", toggle_mode, color=(60, 60, 80), font=font_ui_bold),
        Button(mascon_center_x + 30, val_y, 24, 24, "▲", inc_p, font=font_arrow),
        Button(mascon_center_x + 30, val_y + 26, 24, 24, "▼", dec_p, font=font_arrow),
        Button(elec_brake_center_x + 30, val_y, 24, 24, "▲", inc_b, font=font_arrow),
        Button(elec_brake_center_x + 30, val_y + 26, 24, 24, "▼", dec_b, font=font_arrow),
    ]

    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT: running = False
            for btn in btns: btn.handle_event(event)

        # 入力処理
        b_val, p_pat, raw_btns = get_inputs()
        
        if current_mode == "1": raw_b = ELECTRIC_BRAKE_MAP.get(b_val, -1)
        else: raw_b = AUTO_BRAKE_MAP.get(b_val, -1)
        raw_p = MASCON_LEVEL_MAP.get(p_pat, -1)
        
        filtered_b = brake_filter.update(raw_b)
        filtered_p = mascon_filter.update(raw_p)

        cur_p = min(filtered_p, max_power)
        if current_mode == "1":
            if filtered_b == 9: cur_b = max_brake + 1
            elif filtered_b == 0: cur_b = 0
            else: cur_b = min(filtered_b, max_brake)
        else:
            cur_b = filtered_b

        display_p = 0 if cur_b > 0 else cur_p

        # --- 描画 ---
        screen.fill(COLOR_BG)
        
        # ヘッダー背景
        pygame.draw.rect(screen, COLOR_HEADER_BG, (0, 0, SCREEN_WIDTH, header_h))
        pygame.draw.line(screen, (80,80,80), (0, header_h), (SCREEN_WIDTH, header_h), 1)

        # 現在モード
        center_y = header_h // 2
        lbl_mode_title = font_header_title.render("現在モード: ", True, COLOR_TEXT)
        mode_str = "電気指令式" if current_mode == '1' else "自動空気ブレーキ"
        lbl_mode_val = font_header_title.render(mode_str, True, COLOR_ACCENT)
        
        start_x = 180
        screen.blit(lbl_mode_title, (start_x, center_y - lbl_mode_title.get_height()//2))
        screen.blit(lbl_mode_val, (start_x + lbl_mode_title.get_width(), center_y - lbl_mode_val.get_height()//2))

        # 設定エリア
        lbl_p_t = font_ui_label.render("マスコン段数", True, COLOR_TEXT_DIM)
        t_w = lbl_p_t.get_width()
        screen.blit(lbl_p_t, (mascon_center_x - t_w//2, label_y))
        
        lbl_p_v = font_val.render(f"P{max_power}", True, COLOR_TEXT)
        v_w = lbl_p_v.get_width()
        screen.blit(lbl_p_v, (mascon_center_x - v_w//2 - 10, val_y))

        if current_mode == "1":
            lbl_b_t = font_ui_label.render("ブレーキ段数", True, COLOR_TEXT_DIM)
            t_w = lbl_b_t.get_width()
            screen.blit(lbl_b_t, (elec_brake_center_x - t_w//2, label_y))
            
            lbl_b_v = font_val.render(f"B{max_brake}", True, COLOR_TEXT)
            v_w = lbl_b_v.get_width()
            screen.blit(lbl_b_v, (elec_brake_center_x - v_w//2 - 10, val_y))

        for btn in btns:
            if current_mode == "2" and btn.callback in [inc_b, dec_b]: continue
            btn.draw(screen)

        # 計器描画
        draw_bar_gauge(screen, mascon_center_x, gauge_start_y, display_p, max_power, is_mascon=True)
        
        if current_mode == "1":
            draw_bar_gauge(screen, elec_brake_center_x, gauge_start_y, cur_b, max_brake, is_mascon=False)
        else:
            draw_auto_brake_unit(screen, int(auto_brake_center_x), int(auto_brake_center_y), cur_b)

        # デバッグ情報
        debug_y = 600 - 20 - 25
        b3 = (b_val >> 3) & 1
        b2 = (b_val >> 2) & 1
        b1 = (b_val >> 1) & 1
        b0 = b_val & 1
        
        dbg_str = f"RAW: P={p_pat}  B=({b3}, {b2}, {b1}, {b0})"
        dbg = font_ui_label.render(dbg_str, True, (80, 80, 80))
        screen.blit(dbg, (20, debug_y))

        pygame.display.flip()
        
        # --- キー出力 ---
        if prev_b == 0 and cur_b > 0:
            pydirectinput.press(KEY_MASCON_N)
            time.sleep(KEY_REPEAT_DELAY)
            prev_p = 0

        if current_mode == "2":
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
                is_emergency = (cur_b == max_brake + 1)
                if is_emergency: pydirectinput.keyDown(KEY_BRAKE_EMG)
                else:
                    pydirectinput.keyUp(KEY_BRAKE_EMG)
                    if cur_b == 0: pydirectinput.press(KEY_BRAKE_N)
                    else:
                        diff = cur_b - prev_b
                        for _ in range(abs(diff)):
                            pydirectinput.press(KEY_BRAKE_UP if diff > 0 else KEY_BRAKE_DOWN)
                            time.sleep(KEY_REPEAT_DELAY)

        if cur_b > 0:
            prev_p = 0
        else:
            if cur_p != prev_p:
                if cur_p == 0: pydirectinput.press(KEY_MASCON_N)
                else:
                    diff = cur_p - prev_p
                    for _ in range(abs(diff)):
                        pydirectinput.press(KEY_MASCON_UP if diff > 0 else KEY_MASCON_DOWN)
                        time.sleep(KEY_REPEAT_DELAY)
                prev_p = cur_p

        prev_b = cur_b
        last_auto_s = new_s if current_mode == "2" else 0
        
        is_start, is_select = (raw_btns[9]==1), (raw_btns[10]==1)
        if is_start != p_start:
            pydirectinput.keyDown(KEY_START) if is_start else pydirectinput.keyUp(KEY_START)
            p_start = is_start
        if is_select != p_select:
            pydirectinput.keyDown(KEY_SELECT) if is_select else pydirectinput.keyUp(KEY_SELECT)
            p_select = is_select

        clock.tick(FPS)

    pygame.quit()

if __name__ == "__main__":
    main()