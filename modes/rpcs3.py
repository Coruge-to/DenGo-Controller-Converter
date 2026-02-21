# modes/rpcs3.py
import time
import pydirectinput
from const import *
from .base import BaseLogic

class Rpcs3Logic(BaseLogic):
    def __init__(self):
        super().__init__()
        self.prev_axis = 0

    def reset(self):
        super().reset()
        self.prev_axis = 0
        pydirectinput.keyUp(KEY_PCSX2_POWER_INC)

    def press_emu(self, key):
        pydirectinput.keyDown(key)
        time.sleep(PCSX2_PRESS_DURATION)
        pydirectinput.keyUp(key)
        time.sleep(PCSX2_RELEASE_DURATION)

    def update(self, raw_p, raw_b, raw_btns, context):
        brake_mode = context.get('brake_mode', '1')
        is_keihan = context.get('keihan_mode', False)
        max_brake = context['max_brake']
        
        # 1. 値の補正
        cur_p = raw_p
        cur_b = 0
        if raw_b == 9: cur_b = max_brake + 1
        elif raw_b == 0: cur_b = 0
        else: cur_b = min(raw_b, max_brake)

        # 2. 軸値計算
        cur_axis = 0
        if cur_b == max_brake + 1: cur_axis = -cur_b
        elif cur_b > 0: cur_axis = -cur_b
        else: cur_axis = cur_p

        # 3. 初回同期処理
        if self.needs_sync:
            self.prev_axis = cur_axis
            self.prev_p = cur_p
            self.prev_b = cur_b
            self.needs_sync = False
            return

        # ---------------------------------------------------------
        # 4. 京阪8000系 特殊処理 (定速制御)
        # ---------------------------------------------------------
        if is_keihan:
            # --- パターンA: Pからブレーキへ直接移動した時 ---
            if cur_axis < 0 and self.prev_axis > 0:
                if self.prev_axis == 5:
                    pydirectinput.keyUp(KEY_PCSX2_POWER_INC) # zを離す
                    time.sleep(0.05) # ★リリース・ガード
                self.press_emu(KEY_PCSX2_N)
                time.sleep(PCSX2_RESET_WAIT)
                self.prev_axis = 0
            
            # --- パターンB: P5からP4以下(N含む)へ移動した時 ---
            elif self.prev_axis == 5 and cur_axis < 5:
                pydirectinput.keyUp(KEY_PCSX2_POWER_INC) # zを離す
                # ★リリース・ガード：ここで50ms待つことで、
                # 次の「軸移動ロジック」で送られる q や s との重なりを防ぐ
                time.sleep(0.05) 
                self.prev_axis = 4 # 一旦P4にいたことにして下の軸ロジックへ流す
            
            # --- パターンC: P5に到達し、かつブレーキが0の時 (定速開始) ---
            elif cur_axis == 5 and cur_b == 0:
                if self.prev_axis < 5:
                    # P1-P4からP5へ上がってきた場合、差分を埋めてから長押し開始
                    diff = 4 - max(0, self.prev_axis)
                    if diff > 0:
                        for _ in range(diff): self.press_emu(KEY_PCSX2_POWER_INC)
                    pydirectinput.keyDown(KEY_PCSX2_POWER_INC) # zを押しっぱなしにする
                    self.prev_axis = 5
                self._handle_buttons(raw_btns, is_keihan)
                return

        # ---------------------------------------------------------
        # 5. 軸移動ロジック (通常キー入力)
        # ---------------------------------------------------------
        if cur_axis != self.prev_axis:
            # Nへの復帰 (sキー)
            if cur_axis == 0 and self.prev_axis != 0:
                self.press_emu(KEY_PCSX2_N)
                time.sleep(PCSX2_RESET_WAIT)

            # 力行⇔ブレーキの境界またぎ
            elif (cur_axis > 0 and self.prev_axis < 0) or (cur_axis < 0 and self.prev_axis > 0):
                self.press_emu(KEY_PCSX2_N)
                time.sleep(PCSX2_RESET_WAIT)
                steps = abs(cur_axis)
                if cur_axis > 0:
                    for _ in range(steps): self.press_emu(KEY_PCSX2_POWER_INC)
                else:
                    if brake_mode == "1":
                        for _ in range(steps): self.press_emu(KEY_PCSX2_POWER_DEC)
                    else:
                        for _ in range(steps): self.press_emu(KEY_PCSX2_BRAKE_INC)
            
            # 同一象限内の移動 (P同士 or B同士)
            else:
                diff = cur_axis - self.prev_axis
                if diff > 0: # +方向 (P増 or B減)
                    if cur_axis > 0:
                        for _ in range(abs(diff)): self.press_emu(KEY_PCSX2_POWER_INC)
                    else:
                        if brake_mode == "1":
                            for _ in range(abs(diff)): self.press_emu(KEY_PCSX2_POWER_INC)
                        else:
                            for _ in range(abs(diff)): self.press_emu(KEY_PCSX2_BRAKE_DEC)
                elif diff < 0: # -方向 (P減 or B増)
                    if cur_axis > 0:
                        for _ in range(abs(diff)): self.press_emu(KEY_PCSX2_POWER_DEC)
                    else:
                        if brake_mode == "1":
                            for _ in range(abs(diff)): self.press_emu(KEY_PCSX2_POWER_DEC)
                        else:
                            for _ in range(abs(diff)): self.press_emu(KEY_PCSX2_BRAKE_INC)
            
            self.prev_axis = cur_axis
        
        self._handle_buttons(raw_btns, is_keihan)

    def _handle_buttons(self, raw_btns, is_keihan):
        is_st, is_sl = (raw_btns[9]==1), (raw_btns[10]==1)
        if is_sl != self.p_select:
            pydirectinput.keyDown(KEY_PCSX2_HORN1) if is_sl else pydirectinput.keyUp(KEY_PCSX2_HORN1)
            if is_keihan:
                pydirectinput.keyDown('e') if is_sl else pydirectinput.keyUp('e')
            self.p_select = is_sl
        if is_st != self.p_start:
            pydirectinput.keyDown(KEY_PCSX2_HORN2) if is_st else pydirectinput.keyUp(KEY_PCSX2_HORN2)
            self.p_start = is_st