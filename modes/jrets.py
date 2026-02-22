# modes/jrets.py
import time
import pydirectinput
from const import *
from .base import BaseLogic

class JretsLogic(BaseLogic):
    def __init__(self):
        super().__init__()
        self.last_auto_s = 0

    def reset(self):
        super().reset()
        self.last_auto_s = 0
        pydirectinput.keyUp(KEY_BRAKE_UP)

    def update(self, raw_p, raw_b, raw_btns, context):
        brake_mode = context.get('brake_mode', '1')
        max_brake = context['max_brake']

        # 値の補正
        cur_p = raw_p
        cur_b = 0
        if brake_mode == "1":
            if raw_b == 14: cur_b = max_brake + 1
            elif raw_b == 0: cur_b = 0
            else: cur_b = min(raw_b, max_brake)
        else:
            cur_b = raw_b

        # --- ★追加: 初回同期処理 ---
        if self.needs_sync:
            self.prev_p = cur_p
            self.prev_b = cur_b
            
            # 自動空気ブレーキの初期状態推定
            if brake_mode == "2":
                self.last_auto_s = cur_b
            
            self.needs_sync = False
            return # 初回はここで終了（キー送信しない）
        # ---------------------------

        target_brake_s = 0
        is_logical_run = False

        if brake_mode == "2":
            target_brake_s = cur_b
            is_logical_run = (target_brake_s == 0)
        else:
            is_logical_run = (cur_b == 0)

        if is_logical_run:
            if brake_mode == "1" and self.prev_b > 0:
                pydirectinput.press(KEY_BRAKE_N)
                self.prev_b = 0

            if cur_p != self.prev_p:
                if cur_p == 0:
                    pydirectinput.press(KEY_MASCON_N)
                else:
                    diff = cur_p - self.prev_p
                    key = KEY_MASCON_UP if diff > 0 else KEY_MASCON_DOWN
                    for _ in range(abs(diff)):
                        pydirectinput.press(key)
                        time.sleep(KEY_REPEAT_DELAY)
                self.prev_p = cur_p
        else:
            if self.prev_p != 0:
                pydirectinput.press(KEY_MASCON_N)
                self.prev_p = 0

        if brake_mode == "2":
            if target_brake_s != self.last_auto_s:
                pydirectinput.keyUp(KEY_BRAKE_UP)
                if target_brake_s == 0: pydirectinput.press(KEY_BRAKE_N)
                elif target_brake_s == 2: pydirectinput.keyDown(KEY_BRAKE_UP)
                elif target_brake_s == 3: pydirectinput.press(KEY_BRAKE_EMG)
                self.last_auto_s = target_brake_s
        else:
            if cur_b != self.prev_b:
                if cur_b == max_brake + 1:
                    pydirectinput.press(KEY_BRAKE_EMG)
                elif cur_b == 0:
                    pydirectinput.press(KEY_BRAKE_N)
                else:
                    diff = cur_b - self.prev_b
                    key = KEY_BRAKE_UP if diff > 0 else KEY_BRAKE_DOWN
                    for _ in range(abs(diff)):
                        pydirectinput.press(key)
                        time.sleep(KEY_REPEAT_DELAY)
                self.prev_b = cur_b

        is_st, is_sl = (raw_btns[9]==1), (raw_btns[10]==1)
        if is_st != self.p_start:
            pydirectinput.keyDown(KEY_START) if is_st else pydirectinput.keyUp(KEY_START)
            self.p_start = is_st
        if is_sl != self.p_select:
            pydirectinput.keyDown(KEY_SELECT) if is_sl else pydirectinput.keyUp(KEY_SELECT)
            self.p_select = is_sl