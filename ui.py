# ui.py
import pygame
import math
from const import *

# フォント管理辞書
fonts = {}

def init_fonts():
    """main.pyでpygame.init()した後に呼ぶ"""
    fonts['ui_label'] = pygame.font.SysFont("meiryo", 18, bold=True)
    fonts['ui_bold'] = pygame.font.SysFont("meiryo", 20, bold=True)
    fonts['keihan_bold'] = pygame.font.SysFont("meiryo", 20, bold=True)
    fonts['header_title'] = pygame.font.SysFont("meiryo", 26, bold=True)
    fonts['midosuji_title'] = pygame.font.SysFont("meiryo", 25, bold=True)
    fonts['val'] = pygame.font.SysFont("meiryo", 28, bold=True)
    fonts['gauge'] = pygame.font.SysFont("meiryo", 24, bold=True)
    fonts['gauge_s'] = pygame.font.SysFont("meiryo", 20, bold=True)
    fonts['arrow'] = pygame.font.SysFont("meiryo", 20, bold=True)
    fonts['keihan_b8'] = pygame.font.SysFont("meiryo", 22, bold=True)

class Button:
    def __init__(self, x, y, w, h, text, callback, color=(60,60,60), font_key='ui_bold'):
        self.rect = pygame.Rect(x, y, w, h)
        self.text = text
        self.callback = callback
        self.base_color = color
        self.font_key = font_key
        self.hover = False
        self.visible = True

    def draw(self, surface):
        if not self.visible: return
        pygame.draw.rect(surface, self.base_color, self.rect, border_radius=4)
        
        if self.hover:
            pygame.draw.rect(surface, (255, 255, 255), self.rect, 3, border_radius=4)
        else:
            pygame.draw.rect(surface, (100, 100, 100), self.rect, 1, border_radius=4)
        
        font = fonts.get(self.font_key, fonts['ui_bold'])
        txt_surf = font.render(self.text, True, COLOR_TEXT)
        surface.blit(txt_surf, txt_surf.get_rect(center=self.rect.center))

    def handle_event(self, event):
        if not self.visible: 
            self.hover = False # 非表示ならホバー状態を強制解除
            return

        if event.type == pygame.MOUSEMOTION:
            self.hover = self.rect.collidepoint(event.pos)
        elif event.type == pygame.MOUSEBUTTONDOWN:
            # ★修正: hoverフラグではなく、クリック時点の座標で厳密に判定する
            if self.rect.collidepoint(event.pos) and event.button in [1, 3]:
                self.callback(event.button)

def draw_solid_arc(surface, color, center, r_inner, r_outer, start_deg, end_deg):
    points = []
    cx, cy = center
    step = 0.5 
    angle = start_deg
    while angle <= end_deg:
        rad = math.radians(angle)
        x = cx + r_outer * math.cos(rad)
        y = cy - r_outer * math.sin(rad)
        points.append((x, y))
        angle += step
    rad_end = math.radians(end_deg)
    points.append((cx + r_outer * math.cos(rad_end), cy - r_outer * math.sin(rad_end)))

    angle = end_deg
    while angle >= start_deg:
        rad = math.radians(angle)
        x = cx + r_inner * math.cos(rad)
        y = cy - r_inner * math.sin(rad)
        points.append((x, y))
        angle -= step
    rad_start = math.radians(start_deg)
    points.append((cx + r_inner * math.cos(rad_start), cy - r_inner * math.sin(rad_start)))
    pygame.draw.polygon(surface, color, points)

def draw_bar_gauge(surface, center_x, start_y, current_val, max_val, is_mascon, is_midosuji=False, is_ae100=False, is_keihan=False):
    width = 110
    box_h = 34
    spacing = 6
    x = center_x - width // 2 
    n_rect = pygame.Rect(x, start_y, width, box_h)
    
    col_active = COLOR_P if is_mascon else COLOR_B_SVC
    if is_keihan and not is_mascon: col_active = COLOR_B_SVC

    is_n_active = (current_val == 0)
    if is_n_active:
        pygame.draw.rect(surface, COLOR_N, n_rect, border_radius=3)
        txt_col = (255, 255, 255)
    else:
        pygame.draw.rect(surface, COLOR_OFF_FILL, n_rect, border_radius=3)
        pygame.draw.rect(surface, COLOR_N, n_rect, 1, border_radius=3)
        txt_col = COLOR_TEXT
    
    n_label = "0" if is_keihan else "N"
    ren = fonts['gauge'].render(n_label, True, txt_col)
    surface.blit(ren, ren.get_rect(center=n_rect.center))

    current_y = start_y + box_h + spacing
    for i in range(1, max_val + 1):
        r = pygame.Rect(x, current_y, width, box_h)
        is_active = False
        this_box_color = col_active
        is_keihan_nukitori = (is_keihan and not is_mascon and i == 8)

        if is_mascon:
            is_active = (current_val >= i)
        else:
            if is_keihan: 
                 if current_val == 8 and i == 8: 
                     is_active = True
                     this_box_color = COLOR_B_EMG
                 elif current_val == 8:
                     is_active = False
                 else:
                     is_active = (current_val >= i and current_val <= max_val)
            else:
                is_active = (current_val >= i and current_val <= max_val)

        if is_active:
            pygame.draw.rect(surface, this_box_color, r, border_radius=3)
            txt_col_val = (255, 255, 255)
        else:
            pygame.draw.rect(surface, COLOR_OFF_FILL, r, border_radius=3)
            frame_col = COLOR_B_EMG if is_keihan_nukitori else this_box_color
            pygame.draw.rect(surface, frame_col, r, 1, border_radius=3)
            txt_col_val = COLOR_TEXT

        txt = ""
        font_to_use = fonts['gauge']
        if is_mascon:
            if is_keihan:
                if i==3: txt="－"; 
                elif i==4: txt="N"; 
                elif i==5: txt="＋"; 
                else: txt=f"P{i}"
            elif is_ae100:
                if i==3: txt="－"; 
                elif i==4: txt="H"; 
                elif i==5: txt="＋"; 
                else: txt=f"P{i}"
            else:
                txt = f"P{i}"
        else:
            if is_midosuji: txt = f"B{i+1}"
            elif is_keihan_nukitori:
                txt = "抜取"
                font_to_use = fonts['keihan_b8']
            else: txt = f"B{i}"
            
        ren = font_to_use.render(txt, True, txt_col_val)
        surface.blit(ren, ren.get_rect(center=r.center))
        current_y += box_h + spacing

    if not is_mascon:
        eb_rect = pygame.Rect(x, current_y, width, box_h)
        is_eb = (current_val >= max_val + 1) if is_midosuji else (current_val == max_val + 1)
        
        if is_eb:
            pygame.draw.rect(surface, COLOR_B_EMG, eb_rect, border_radius=3)
            t_col = (255, 255, 255)
        else:
            pygame.draw.rect(surface, COLOR_OFF_FILL, eb_rect, border_radius=3)
            pygame.draw.rect(surface, COLOR_B_EMG, eb_rect, 1, border_radius=3)
            t_col = COLOR_TEXT
        
        ren = fonts['gauge'].render("EB", True, t_col)
        surface.blit(ren, ren.get_rect(center=eb_rect.center))

def draw_auto_brake_unit(surface, center_x, center_y, current_val):
    center = (center_x, center_y)
    label_radius = 180 
    r_inner, r_outer = 172, 188
    overlap_angle = 10
    
    col_run = COLOR_N if current_val == 0 else COLOR_OFF_FILL
    col_svc = COLOR_B_SVC if current_val == 8 else COLOR_OFF_FILL
    
    draw_solid_arc(surface, col_run, center, r_inner, r_outer, 200, 270 + overlap_angle)
    draw_solid_arc(surface, col_svc, center, r_inner, r_outer, 270 - overlap_angle, 380)
    
    angles = { 0: 200, 6: 270, 8: 330, 9: 20 }
    target_angle = angles.get(current_val, 200)
    
    labels = [(0, "運転", 200, COLOR_N), (6, "重なり", 270, COLOR_B_SVC), 
              (8, "常用", 330, COLOR_B_SVC), (9, "非常", 20, COLOR_B_EMG)]
    
    for val, text, ang, act_color in labels:
        lx = center[0] + label_radius * math.cos(math.radians(ang))
        ly = center[1] - label_radius * math.sin(math.radians(ang))
        is_active = (current_val == val)
        pygame.draw.circle(surface, act_color if is_active else COLOR_OFF_FILL, (int(lx), int(ly)), 40)
        if not is_active:
            pygame.draw.circle(surface, act_color, (int(lx), int(ly)), 40, 2)
        ren = fonts['gauge_s'].render(text, True, (255,255,255) if is_active else COLOR_TEXT)
        surface.blit(ren, ren.get_rect(center=(int(lx), int(ly))))
        
    angle_rad = math.radians(-target_angle)
    brass_len, wood_len = 35, 100
    pygame.draw.line(surface, COLOR_HANDLE_BRASS, center, 
                     (center[0] + (brass_len+30) * math.cos(angle_rad), center[1] + (brass_len+30) * math.sin(angle_rad)), 16)
    
    grip_center_dist = brass_len + wood_len / 2
    grip_w = 28
    ox, oy = 0.6 * math.sin(angle_rad), -0.6 * math.cos(angle_rad) 
    grip_surf = pygame.Surface((wood_len, grip_w), pygame.SRCALPHA)
    pygame.draw.polygon(grip_surf, COLOR_HANDLE_WOOD, 
                        [(0, grip_w//2 - 10), (wood_len - 15, grip_w//2 - 14), 
                         (wood_len - 15, grip_w//2 + 14), (0, grip_w//2 + 10)])
    pygame.draw.circle(grip_surf, COLOR_HANDLE_WOOD, (wood_len - 15, grip_w//2), 14)
    
    rotated_grip = pygame.transform.rotate(grip_surf, target_angle)
    grip_x = center[0] + grip_center_dist * math.cos(angle_rad) + ox
    grip_y = center[1] + grip_center_dist * math.sin(angle_rad) + oy
    surface.blit(rotated_grip, rotated_grip.get_rect(center=(grip_x, grip_y)))
    
    pygame.draw.circle(surface, COLOR_HANDLE_BRASS, center, 16)
    hole_surf = pygame.Surface((14, 14), pygame.SRCALPHA); hole_surf.fill(COLOR_HOLE)
    rotated_hole = pygame.transform.rotate(hole_surf, target_angle)
    surface.blit(rotated_hole, rotated_hole.get_rect(center=center))

# --- タイトル描画ロジック ---
def draw_header_title(surface, game_mode, brake_mode, midosuji_mode, ae100_mode, keihan_mode, mode_787, header_h):
    lbl_mode_title = fonts['header_title'].render("現在モード: ", True, COLOR_TEXT)
    
    if game_mode in ["PCSX2", "RPCS3"]:
        if midosuji_mode:
            mode_name_str = "御堂筋線"
            header_color = COLOR_MIDOSUJI
        elif ae100_mode:
            mode_name_str = "AE100形"
            header_color = COLOR_AE100_TXT
        elif mode_787:
            mode_name_str = "787系"
            header_color = COLOR_787_TXT
        elif keihan_mode:
            mode_name_str = "京阪8000系"
            header_color = COLOR_KEIHAN_RED
        else:
            mode_name_str = "1ハンドル" if brake_mode == '1' else "2ハンドル"
            header_color = COLOR_ACCENT
    else:
        mode_name_str = "電気指令式" if brake_mode == '1' else "自動空気ブレーキ"
        header_color = COLOR_ACCENT

    lbl_mode_val = None
    
    if mode_name_str == "AE100形":
        col_stripe_blue = (0, 84, 171)
        col_stripe_red = (213, 44, 48)
        col_text = (237, 226, 212) 
        base_surf = fonts['midosuji_title'].render(mode_name_str, True, col_text)
        w_text, h_text = base_surf.get_size()
        padding_x = 2
        stripe_h = 4 
        box_w = w_text + padding_x * 2
        box_h = h_text
        lbl_mode_val = pygame.Surface((box_w, box_h), pygame.SRCALPHA)
        lbl_mode_val.blit(base_surf, (padding_x, 0))
        rect_blue = pygame.Rect(0, box_h - (stripe_h * 2), box_w, stripe_h)
        pygame.draw.rect(lbl_mode_val, col_stripe_blue, rect_blue)          
        rect_red = pygame.Rect(1, box_h - stripe_h, box_w, stripe_h)
        pygame.draw.rect(lbl_mode_val, col_stripe_red, rect_red)

    elif mode_name_str == "京阪8000系":
        base_surf = fonts['keihan_bold'].render(mode_name_str, True, COLOR_KEIHAN_GOLD)
        w_text, h_text = base_surf.get_size()
        padding_x = 10
        padding_y = 6
        box_w = w_text + padding_x * 2
        box_h = h_text + padding_y * 2
        lbl_mode_val = pygame.Surface((box_w, box_h), pygame.SRCALPHA)
        rect_bg = pygame.Rect(0, 0, box_w, box_h)
        pygame.draw.rect(lbl_mode_val, COLOR_KEIHAN_RED, rect_bg, border_radius=4)
        lbl_mode_val.blit(base_surf, (padding_x, padding_y))

    elif mode_name_str == "御堂筋線":
        base_surf = fonts['midosuji_title'].render(mode_name_str, True, header_color)
        outline_surf = fonts['midosuji_title'].render(mode_name_str, True, (235, 235, 235))
        stroke = 2
        w, h = base_surf.get_size()
        lbl_mode_val = pygame.Surface((w + stroke*2, h + stroke*2), pygame.SRCALPHA)
        for dx in range(-stroke, stroke + 1):
            for dy in range(-stroke, stroke + 1):
                if dx*dx + dy*dy > stroke*stroke + 1: continue 
                lbl_mode_val.blit(outline_surf, (stroke + dx, stroke + dy))
        lbl_mode_val.blit(base_surf, (stroke, stroke))
        
    else:
        lbl_mode_val = fonts['header_title'].render(mode_name_str, True, header_color)

    rect_title = lbl_mode_title.get_rect()
    base_center_y = header_h // 2
    rect_title.midleft = (170, base_center_y)
    
    rect_val = lbl_mode_val.get_rect()
    rect_val.midleft = (rect_title.right, base_center_y)
    
    surface.blit(lbl_mode_title, rect_title)
    surface.blit(lbl_mode_val, rect_val)