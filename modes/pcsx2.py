# modes/pcsx2.py
import time
from const import *
from .base import BaseLogic

class Pcsx2Logic(BaseLogic):
    def __init__(self, sender):
        super().__init__()
        self.sender = sender
        self.prev_axis = 0

    def reset(self):
        self.sender.neutralize()
        super().reset()
        self.prev_axis = 0

    def press_emu(self, button):
        self.sender.press(button, PCSX2_PRESS_DURATION)
        time.sleep(PCSX2_RELEASE_DURATION)

    def update(self, raw_p, raw_b, raw_btns, context):
        brake_mode = context.get('brake_mode', '1')
        is_midosuji = context.get('midosuji_mode', False)
        is_ae100 = context.get('ae100_mode', False)
        is_787 = context.get('mode_787', False)
        max_brake = context['max_brake']

        # 1. 値の補正
        cur_p = raw_p
        cur_b = 0
        if raw_b == 14: cur_b = max_brake + 1
        elif raw_b == 0: cur_b = 0
        else:
            if is_midosuji and raw_b > max_brake: cur_b = max_brake
            else: cur_b = min(raw_b, max_brake)

        # 2. 軸値計算
        cur_axis = 0
        if cur_b == max_brake + 1: cur_axis = -cur_b
        elif cur_b > 0: cur_axis = -cur_b
        else: cur_axis = cur_p

        # 3. Initial synchronization
        if self.needs_sync:
            self.prev_axis = cur_axis
            self.prev_p = cur_p
            self.prev_b = cur_b
            self.needs_sync = False
            return

        is_start = raw_btns[9] == 1
        is_select = raw_btns[10] == 1
        if is_start != self.p_start:
            if is_start:
                self.sender.button_down(VGPAD_PCSX2_START)
            else:
                self.sender.button_up(VGPAD_PCSX2_START)
            self.p_start = is_start
        if is_select != self.p_select:
            if is_select:
                self.sender.button_down(VGPAD_PCSX2_SELECT)
            else:
                self.sender.button_up(VGPAD_PCSX2_SELECT)
            self.p_select = is_select

        B_INC = VGPAD_PCSX2_BRAKE_DEC if is_midosuji else VGPAD_PCSX2_BRAKE_INC
        B_DEC = VGPAD_PCSX2_BRAKE_INC if is_midosuji else VGPAD_PCSX2_BRAKE_DEC

        # ---------------------------------------------------------
        # 4. AE100 特殊処理 (定速制御)
        # ---------------------------------------------------------
        if is_ae100:
            # --- パターンA: Pからブレーキへ移動した時 ---
            if cur_axis < 0 and self.prev_axis > 0:
                if self.prev_axis == 5:
                    self.sender.button_up(VGPAD_PCSX2_POWER_INC) # zを離す
                    time.sleep(0.05) # ★リリース・ガード
                self.press_emu(VGPAD_PCSX2_N)
                time.sleep(PCSX2_RESET_WAIT)
                self.prev_axis = 0
            
            # --- パターンB: P5からP4以下へ移動した時 ---
            elif self.prev_axis == 5 and cur_axis < 5:
                self.sender.button_up(VGPAD_PCSX2_POWER_INC) # zを離す
                time.sleep(0.05) # ★リリース・ガード
                self.prev_axis = 4 # 一旦P4にいたことにして下の軸ロジックへ流す
            
            # --- パターンC: P5に到達し、かつブレーキが0の時 (定速開始) ---
            elif cur_axis == 5 and cur_b == 0:
                if self.prev_axis < 5:
                    diff = 4 - max(0, self.prev_axis)
                    if diff > 0:
                        for _ in range(diff): self.press_emu(VGPAD_PCSX2_POWER_INC)
                    self.sender.button_down(VGPAD_PCSX2_POWER_INC)
                    self.prev_axis = 5
                return

        # ---------------------------------------------------------
        # 5. 軸移動ロジック
        # ---------------------------------------------------------
        if cur_axis != self.prev_axis:
            # 非常ブレーキ
            if cur_axis == -(max_brake + 1) and not is_787:
                self.press_emu(VGPAD_PCSX2_EMG)
            
            # Nへの復帰
            elif cur_axis == 0 and self.prev_axis != 0:
                self.press_emu(VGPAD_PCSX2_N)
                time.sleep(PCSX2_RESET_WAIT)
            
            # 境界またぎ
            elif (cur_axis > 0 and self.prev_axis < 0) or (cur_axis < 0 and self.prev_axis > 0):
                self.press_emu(VGPAD_PCSX2_N)
                time.sleep(PCSX2_RESET_WAIT)
                steps = abs(cur_axis)
                if cur_axis > 0:
                    for _ in range(steps): self.press_emu(VGPAD_PCSX2_POWER_INC)
                else:
                    if brake_mode == "1":
                        for _ in range(steps): self.press_emu(VGPAD_PCSX2_POWER_DEC)
                    else:
                        for _ in range(steps): self.press_emu(B_INC)
            
            # 同一象限内
            else:
                diff = cur_axis - self.prev_axis
                if diff > 0: # +方向
                    if cur_axis > 0:
                        for _ in range(abs(diff)): self.press_emu(VGPAD_PCSX2_POWER_INC)
                    else:
                        if brake_mode == "1":
                            for _ in range(abs(diff)): self.press_emu(VGPAD_PCSX2_POWER_INC)
                        else:
                            for _ in range(abs(diff)): self.press_emu(B_DEC)
                elif diff < 0: # -方向
                    if cur_axis > 0:
                        for _ in range(abs(diff)): self.press_emu(VGPAD_PCSX2_POWER_DEC)
                    else:
                        if brake_mode == "1":
                            for _ in range(abs(diff)): self.press_emu(VGPAD_PCSX2_POWER_DEC)
                        else:
                            for _ in range(abs(diff)): self.press_emu(B_INC)
            
            self.prev_axis = cur_axis