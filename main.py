# main.py
import sys
import os
import ctypes
import pygame
import pydirectinput

from const import *
from inputs import get_inputs, StableNotchReader
import ui 
from ui import Button, draw_bar_gauge, draw_auto_brake_unit, draw_header_title

from modes.jrets import JretsLogic
from modes.bve import BveLogic
from modes.pcsx2 import Pcsx2Logic
from modes.rpcs3 import Rpcs3Logic
from modes.running_train import RunningLogic
from bve_vehicle_spec import BveVehicleSpecReceiver
from platform_detection import EfficientPlatformDetector

try:
    myappid = 'my.dengo.converter.v21.ux_improved'
    ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(myappid)
except:
    pass
os.environ["SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS"] = "1"
pydirectinput.PAUSE = 0

game_mode = "JRETS"
brake_mode = "1"
max_power = 5
max_brake = 8

# ★特殊モードフラグ
midosuji_mode = False
ae100_mode = False
keihan_mode = False
mode_787 = False
yokusoku_mode = False

logics = {
    "JRETS": JretsLogic(),
    "BVE": BveLogic(),
    "PCSX2": Pcsx2Logic(),
    "RPCS3": Rpcs3Logic(),
    "RUNNING": RunningLogic()
}

def force_reset_state(*args):
    logics[game_mode].reset()
    print(f"State Reset Executed for {game_mode}.")

def set_game_mode(new_mode):
    global game_mode, max_power, max_brake, brake_mode, midosuji_mode, ae100_mode, keihan_mode, mode_787, yokusoku_mode
    if new_mode == game_mode: return False
    game_mode = new_mode
    midosuji_mode = ae100_mode = keihan_mode = mode_787 = yokusoku_mode = False
    max_power, max_brake, brake_mode = 5, 8, "1"
    logics[game_mode].reset(); return True

def toggle_game_mode(mouse_btn=1, *args):
    modes=["JRETS","BVE","PCSX2","RPCS3","RUNNING"];idx=modes.index(game_mode);set_game_mode(modes[(idx+1)%len(modes) if mouse_btn==1 else (idx-1)%len(modes)])

def toggle_brake_mode(*args):
    global brake_mode, midosuji_mode, ae100_mode, keihan_mode, mode_787, yokusoku_mode, max_power, max_brake
    if midosuji_mode or ae100_mode or keihan_mode or mode_787 or yokusoku_mode:
        midosuji_mode = False
        ae100_mode = False
        keihan_mode = False
        mode_787 = False
        yokusoku_mode = False
        max_power = 5
        max_brake = 8
        brake_mode = "1"
    else:
        brake_mode = "2" if brake_mode == "1" else "1"
    logics[game_mode].reset()

def toggle_yokusoku(*args):
    global yokusoku_mode
    yokusoku_mode = not yokusoku_mode

def toggle_midosuji(*args):
    global midosuji_mode, brake_mode, max_power, max_brake, ae100_mode, keihan_mode, mode_787
    if not midosuji_mode:
        midosuji_mode = True
        ae100_mode = False; keihan_mode = False; mode_787 = False
        brake_mode = "2"; max_power = 4; max_brake = 6
    else:
        midosuji_mode = False

def toggle_ae100(*args):
    global ae100_mode, midosuji_mode, brake_mode, max_power, max_brake, keihan_mode, mode_787
    if not ae100_mode:
        ae100_mode = True
        midosuji_mode = False; keihan_mode = False; mode_787 = False
        brake_mode = "1"; max_power = 5; max_brake = 5
    else:
        ae100_mode = False

def toggle_keihan(*args):
    global keihan_mode, ae100_mode, midosuji_mode, brake_mode, max_power, max_brake, mode_787
    if not keihan_mode:
        keihan_mode = True
        midosuji_mode = False; ae100_mode = False; mode_787 = False
        brake_mode = "1"; max_power = 5; max_brake = 8
    else:
        keihan_mode = False

# ★追加: 787系モード切替
def toggle_787(*args):
    global mode_787, ae100_mode, midosuji_mode, keihan_mode, brake_mode, max_power, max_brake
    if not mode_787:
        mode_787 = True
        midosuji_mode = False; ae100_mode = False; keihan_mode = False
        brake_mode = "2" # ツーハンドル固定
        max_power = 5; max_brake = 7
    else:
        mode_787 = False

def inc_p(*args): 
    global max_power
    if midosuji_mode or ae100_mode or keihan_mode or mode_787: return
    max_power = min(5, max_power + 1)

def dec_p(*args): 
    global max_power
    if midosuji_mode or ae100_mode or keihan_mode or mode_787: return
    max_power = max(1, max_power - 1)

def inc_b(*args): 
    global max_brake
    if midosuji_mode or ae100_mode or keihan_mode or mode_787: return
    max_brake = min(13, max_brake + 1)

def dec_b(*args): 
    global max_brake
    if midosuji_mode or ae100_mode or keihan_mode or mode_787: return
    max_brake = max(1, max_brake - 1)

def resource_path(relative_path):
    try:
        base_path = sys._MEIPASS
    except Exception:
        base_path = os.path.abspath(".")
    return os.path.join(base_path, relative_path)

# これ追加!!!
def get_dynamic_height(game_mode, brake_mode, max_power, max_brake):
    box_h, spacing = 34, 6
    gauge_start_y = 180
    bottom_margin = 40 # 一番下のデバッグ文字用の余白

    # マスコン側 (N + P1〜Pmax)
    p_height = gauge_start_y + (max_power + 1) * (box_h + spacing)

    # ブレーキ側
    is_real_auto_air = (game_mode in ["JRETS", "BVE", "RUNNING"] and brake_mode == "2")
    if is_real_auto_air:
        # 自動空気ブレーキ: 中心(250) + アーム長(180) + ラベル円(40)
        b_height = 420
    else:
        # 電気指令式: N + B1〜Bmax + EB
        b_height = gauge_start_y + (max_brake + 2) * (box_h + spacing)

    # 左右で長い方に合わせる（最低でも600pxは確保）
    req_h = max(p_height, b_height) + bottom_margin
    return max(req_h, 0)

def main():
    pygame.init()
    pygame.display.set_caption("DenGo Controller Converter")
    icon_path = resource_path("DenGo-Controller-Converter.ico")
    if os.path.exists(icon_path):
        icon = pygame.image.load(icon_path)
        pygame.display.set_icon(icon)
    
    screen = pygame.display.set_mode((SCREEN_WIDTH, SCREEN_HEIGHT))
    pygame.display.set_caption("DenGo Controller Converter")
    
    try:
        base_path = getattr(sys, '_MEIPASS', os.path.dirname(os.path.abspath(__file__)))
        icon_path = os.path.join(base_path, "DenGo-Controller-Converter.png")
        if os.path.exists(icon_path):
            pygame.display.set_icon(pygame.image.load(icon_path))
    except:
        pass

    screen = pygame.display.set_mode((SCREEN_WIDTH, SCREEN_HEIGHT))
    clock = pygame.time.Clock()
    ui.init_fonts()

    pygame.joystick.init()
    joy = pygame.joystick.Joystick(0) if pygame.joystick.get_count() > 0 else None
    if joy: joy.init()

    mascon_filter = StableNotchReader(0)
    brake_filter = StableNotchReader(0)
    bve_spec_receiver = BveVehicleSpecReceiver()
    platform_detector = EfficientPlatformDetector(probe_interval=0.20, full_resync_interval=3.0)
    last_bve_control_config = None

    header_h, label_y, val_y, gauge_start_y = 70, 90, 120, 180
    mascon_cx, elec_brake_cx = MARGIN_SIDE + 50, SCREEN_WIDTH - MARGIN_SIDE - 50
    reset_x, pcsx2_btn_x = SCREEN_WIDTH - 20 - 100, SCREEN_WIDTH - 20 - 100 - 10 - 100
    midosuji_btn_x = pcsx2_btn_x - 10 - 60

    btn_reset = Button(reset_x, (header_h - 40)//2, 100, 40, "リセット", force_reset_state, color=(60, 60, 80))
    btn_game_mode = Button(pcsx2_btn_x, (header_h - 40)//2, 100, 40, "JRETS", toggle_game_mode, color=COLOR_N)
    btn_game_mode.interactive = False
    btn_brake_mode = Button(20, (header_h - 40)//2, 140, 40, "モード切替", toggle_brake_mode, color=(60, 60, 80))
    
    btn_midosuji = Button(midosuji_btn_x, (header_h - 40)//2, 60, 40, "通常", toggle_midosuji, color=COLOR_NORMAL_BTN)
    btn_ae100 = Button(midosuji_btn_x, (header_h - 40)//2, 60, 40, "通常", toggle_ae100, color=COLOR_NORMAL_BTN)
    btn_keihan = Button(midosuji_btn_x, (header_h - 40)//2, 60, 40, "通常", toggle_keihan, color=COLOR_NORMAL_BTN)
    btn_787 = Button(midosuji_btn_x, (header_h - 40)//2, 60, 40, "通常", toggle_787, color=COLOR_NORMAL_BTN)
    btn_yokusoku = Button(midosuji_btn_x, (header_h - 40)//2, 60, 40, "通常", toggle_yokusoku, color=COLOR_NORMAL_BTN)

    offset_btn = 40
    btns_cfg = [
        Button(mascon_cx - offset_btn - 14, val_y + 10, 24, 24, "－", dec_p, font_key='arrow'), 
        Button(mascon_cx + offset_btn - 9, val_y + 10, 24, 24, "＋", inc_p, font_key='arrow'),
        Button(elec_brake_cx - offset_btn - 14, val_y + 10, 24, 24, "－", dec_b, font_key='arrow'),
        Button(elec_brake_cx + offset_btn - 9, val_y + 10, 24, 24, "＋", inc_b, font_key='arrow'),
    ]

    all_btns = [btn_brake_mode, btn_game_mode, btn_reset, btn_midosuji, btn_ae100, btn_keihan, btn_787, btn_yokusoku] + btns_cfg

    last_visual_state = None

    running = True
    while running:
        for event in pygame.event.get():
            if event.type == pygame.QUIT: running = False
            for btn in all_btns:
                btn.handle_event(event)

        platform_statuses=platform_detector.update()
        running_platforms=tuple(s for s in platform_statuses if s.running)
        platform_count=sum(len(s.process_ids) for s in running_platforms)
        if platform_count==1:
            s=next(s for s in running_platforms if s.process_ids)
            set_game_mode({"jrets":"JRETS","bve5":"BVE","bve6":"BVE","pcsx2":"PCSX2","rpcs3":"RPCS3","running_train":"RUNNING"}[s.platform_id])
        effective_brake_mode = brake_mode
        effective_max_power = max_power
        effective_max_brake = max_brake
        effective_yokusoku_mode = yokusoku_mode

        bve_process_count=sum(len(s.process_ids) for s in platform_statuses if s.platform_id in ("bve5","bve6"))
        if game_mode == "BVE" and bve_process_count == 1:
            vehicle_spec = bve_spec_receiver.read()
            if vehicle_spec is not None:
                effective_max_power = vehicle_spec.power_notch_count
                if vehicle_spec.brake_system == "Cl":
                    effective_brake_mode = "2"
                    effective_yokusoku_mode = False
                else:
                    effective_brake_mode = "1"
                    effective_max_brake = vehicle_spec.brake_notch_count
                    effective_yokusoku_mode = vehicle_spec.has_holding_speed_brake

            bve_control_config = (
                None if vehicle_spec is None else vehicle_spec.writer_process_id,
                None if vehicle_spec is None else vehicle_spec.generation,
                effective_brake_mode,
                effective_max_power,
                effective_max_brake,
                effective_yokusoku_mode,
            )
            if bve_control_config != last_bve_control_config:
                logics["BVE"].reset()
                last_bve_control_config = bve_control_config
        else:
            bve_spec_receiver.disconnect()
            last_bve_control_config = None

        btn_brake_mode.interactive = game_mode != "BVE"
        btn_yokusoku.interactive = game_mode != "BVE"

        # 特殊モードボタンの出現条件
        btn_midosuji.visible = (game_mode == "PCSX2") and (midosuji_mode or max_brake == 6)
        btn_ae100.visible = (game_mode == "PCSX2") and (ae100_mode or max_brake == 5)
        btn_787.visible = (game_mode == "PCSX2") and (mode_787 or max_brake == 7) # ★追加
        btn_keihan.visible = (game_mode == "RPCS3") and (keihan_mode or max_brake == 8)
        btn_yokusoku.visible = (game_mode in ["JRETS", "BVE"]) and (effective_brake_mode == "1")

        is_special = (midosuji_mode or ae100_mode or keihan_mode or mode_787)
        is_real_auto_air = (game_mode in ["JRETS", "BVE", "RUNNING"] and effective_brake_mode == "2")

        btns_cfg[0].visible = game_mode != "BVE" and not is_special
        btns_cfg[1].visible = game_mode != "BVE" and not is_special
        btns_cfg[2].visible = game_mode != "BVE" and not is_special and not is_real_auto_air
        btns_cfg[3].visible = game_mode != "BVE" and not is_special and not is_real_auto_air

        if game_mode == "RUNNING":
            btn_game_mode.text = "RUNNING\nTRAIN"
            btn_game_mode.font_key = 'ui_bold_s' # ★小さいフォントを適用
            btn_game_mode.base_color = COLOR_RUNNING
        else:
            btn_game_mode.text = game_mode
            btn_game_mode.font_key = 'ui_bold'   # ★他のモードは通常の大きさに戻す
            
            if game_mode == "JRETS": btn_game_mode.base_color = COLOR_N
            elif game_mode == "BVE": btn_game_mode.base_color = COLOR_B_SVC
            elif game_mode == "PCSX2": btn_game_mode.base_color = COLOR_P
            elif game_mode == "RPCS3": btn_game_mode.base_color = COLOR_RPCS3_BTN

        if midosuji_mode: btn_midosuji.text = "反転"; btn_midosuji.base_color = COLOR_MIDOSUJI
        else: btn_midosuji.text = "通常"; btn_midosuji.base_color = COLOR_NORMAL_BTN
            
        if ae100_mode: btn_ae100.text = "定速"; btn_ae100.base_color = COLOR_AE100_BTN
        else: btn_ae100.text = "通常"; btn_ae100.base_color = COLOR_NORMAL_BTN

        if mode_787: btn_787.text = "特殊"; btn_787.base_color = COLOR_787_BTN
        else: btn_787.text = "通常"; btn_787.base_color = COLOR_NORMAL_BTN

        if keihan_mode: btn_keihan.text = "定速"; btn_keihan.base_color = COLOR_AE100_BTN
        else: btn_keihan.text = "通常"; btn_keihan.base_color = COLOR_NORMAL_BTN

        if effective_yokusoku_mode: btn_yokusoku.text = "抑速"; btn_yokusoku.base_color = COLOR_B_SVC
        else: btn_yokusoku.text = "通常"; btn_yokusoku.base_color = COLOR_NORMAL_BTN

        b_val, p_pat, raw_btns = get_inputs(joy)
        
        if game_mode in ["PCSX2", "RPCS3"]:
             raw_b = ELECTRIC_BRAKE_MAP.get(b_val, -1)
        else:
             raw_b = ELECTRIC_BRAKE_MAP.get(b_val, -1) if effective_brake_mode == "1" else AUTO_BRAKE_MAP.get(b_val, -1)
        
        raw_p = MASCON_LEVEL_MAP.get(p_pat, -1)

        cur_p = min(mascon_filter.update(raw_p), effective_max_power)
        cur_b = brake_filter.update(raw_b)
        
        if game_mode in ["PCSX2", "RPCS3"]:
             if cur_b == 14: display_b = effective_max_brake + 1
             elif midosuji_mode and cur_b > effective_max_brake: display_b = effective_max_brake
             else: display_b = min(cur_b, effective_max_brake)
        elif effective_brake_mode == "1":
             if cur_b == 14: display_b = effective_max_brake + 1
             else: display_b = min(cur_b, effective_max_brake)
        else:
             display_b = cur_b 
        display_p = 0 if display_b > 0 else cur_p

        current_visual_state = (
            game_mode, effective_brake_mode, 
            effective_max_power, effective_max_brake,
            midosuji_mode, ae100_mode, keihan_mode, mode_787, effective_yokusoku_mode,
            display_p, display_b,
            tuple(b.hover for b in all_btns if b.visible),
            b_val, p_pat, tuple((s.platform_id,s.running,s.process_ids) for s in platform_statuses)
        )

        if current_visual_state != last_visual_state:
            # ★ 追加: ウィンドウの伸縮処理
            req_h = 260 if platform_count != 1 else get_dynamic_height(game_mode, effective_brake_mode, effective_max_power, effective_max_brake)
            if screen.get_height() != req_h:
                screen = pygame.display.set_mode((SCREEN_WIDTH, req_h))

            screen.fill(COLOR_BG)
            pygame.draw.rect(screen, COLOR_HEADER_BG, (0, 0, SCREEN_WIDTH, header_h))
            pygame.draw.line(screen, (80,80,80), (0, header_h), (SCREEN_WIDTH, header_h), 1)
            
            draw_header_title(screen, game_mode, effective_brake_mode, midosuji_mode, ae100_mode, keihan_mode, mode_787, header_h)

            # --- マスコン段数の文字 ---
            lbl_p_t = ui.fonts['ui_label'].render("マスコン段数", True, COLOR_TEXT_DIM)
            screen.blit(lbl_p_t, lbl_p_t.get_rect(center=(mascon_cx, label_y + 10)))
            
            # マスコンは最大5段
            lbl_p_v = ui.fonts['val'].render(f"{effective_max_power}段", True, COLOR_TEXT)
            screen.blit(lbl_p_v, lbl_p_v.get_rect(midright=(mascon_cx + 24, val_y + 22))) # 座標はキープ！

            # --- ブレーキ段数の文字 ---
            if not is_real_auto_air:
                lbl_b_t = ui.fonts['ui_label'].render("ブレーキ段数", True, COLOR_TEXT_DIM)
                screen.blit(lbl_b_t, lbl_b_t.get_rect(center=(elec_brake_cx, label_y + 10)))
                
                # 10段以上の時は val_small を使ってUIを整える
                b_font = ui.fonts['val_small'] if effective_max_brake >= 10 else ui.fonts['val']
                b_offset_x = 2 if max_brake >= 10 else 0
                lbl_b_v = b_font.render(f"{effective_max_brake}段", True, COLOR_TEXT)
                screen.blit(lbl_b_v, lbl_b_v.get_rect(midright=(elec_brake_cx + 24 + b_offset_x, val_y + 22)))

            draw_bar_gauge(screen, mascon_cx, gauge_start_y, display_p, effective_max_power, True, is_ae100=ae100_mode, is_keihan=keihan_mode)
            
            if not is_real_auto_air:
                draw_bar_gauge(screen, elec_brake_cx, gauge_start_y, display_b, effective_max_brake, False, is_midosuji=midosuji_mode, is_keihan=keihan_mode, is_yokusoku=effective_yokusoku_mode)
            else:
                auto_cx = (SCREEN_WIDTH - MARGIN_SIDE) - 40 - (180 * 0.94) 
                draw_auto_brake_unit(screen, int(auto_cx), 193, display_b)

            for btn in all_btns:
                if btn.visible: btn.draw(screen)

            b_bits = [(b_val >> 3) & 1, (b_val >> 2) & 1, (b_val >> 1) & 1, b_val & 1]
            b_fmt_str = f"B=({b_bits[0]}, {b_bits[1]}, {b_bits[2]}, {b_bits[3]})"
            dbg_str = f"RAW: P={p_pat} {b_fmt_str} GAME={game_mode}"
            dbg = ui.fonts['ui_label'].render(dbg_str, True, (80, 80, 80))
            
            # ★ 修正: SCREEN_HEIGHT ではなく、現在の screen.get_height() の下端に追従させる
            screen.blit(dbg, (20, screen.get_height() - 30))
            if platform_count != 1: ui.draw_platform_gate_screen(screen, platform_statuses, platform_count)
            pygame.display.flip()
            last_visual_state = current_visual_state

        # ★contextに mode_787 を追加
        context = {
            "game_mode": game_mode,
            "brake_mode": effective_brake_mode,
            "max_power": effective_max_power,
            "max_brake": effective_max_brake,
            "midosuji_mode": midosuji_mode,
            "ae100_mode": ae100_mode,
            "keihan_mode": keihan_mode,
            "mode_787": mode_787 
        }
        logics[game_mode].update(cur_p, cur_b, raw_btns, context)
        
        clock.tick(FPS)

    bve_spec_receiver.close()
    pygame.quit()

if __name__ == "__main__":
    main()
