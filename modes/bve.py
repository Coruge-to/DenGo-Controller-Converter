# modes/bve.py
import time
import pydirectinput
from const import *
from .base import BaseLogic

class BveLogic(BaseLogic):
    def __init__(self):
        super().__init__()
        self.auto_state = 0 

    def reset(self):
        super().reset()
        self.auto_state = 0

    def update(self, raw_p, raw_b, raw_btns, context):
        brake_mode = context.get('brake_mode', '1')
        max_brake = context['max_brake']

        cur_p = raw_p
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
            
            # 自動空気ブレーキの位置推定
            if brake_mode == "2":
                self.auto_state = cur_b
            
            self.needs_sync = False
            return
        # ---------------------------

        if cur_b <= 0:
            if brake_mode == "2":
                target_state = 0
                if self.auto_state != 0:
                    diff = target_state - self.auto_state
                    for _ in range(abs(diff)):
                        pydirectinput.press(KEY_BRAKE_DOWN)
                        time.sleep(KEY_REPEAT_DELAY)
                    self.auto_state = 0
            
            if brake_mode == "1" and self.prev_b > 0:
                steps_to_release = self.prev_b
                for _ in range(steps_to_release):
                    pydirectinput.press(KEY_BRAKE_DOWN)
                    time.sleep(KEY_REPEAT_DELAY)
                self.prev_b = 0

            if cur_p != self.prev_p:
                diff = cur_p - self.prev_p
                if diff > 0:
                    for _ in range(diff): 
                        pydirectinput.press(KEY_MASCON_UP)
                        time.sleep(KEY_REPEAT_DELAY)
                elif diff < 0:
                    for _ in range(abs(diff)): 
                        pydirectinput.press(KEY_MASCON_DOWN)
                        time.sleep(KEY_REPEAT_DELAY)
                self.prev_p = cur_p

        else:
            if self.prev_p != 0:
                diff = 0 - self.prev_p
                for _ in range(abs(diff)): 
                    pydirectinput.press(KEY_MASCON_DOWN)
                    time.sleep(KEY_REPEAT_DELAY)
                self.prev_p = 0
            
            if brake_mode == "2":
                target_state = cur_b
                
                if target_state == 3 and self.auto_state != 3:
                    pydirectinput.press(KEY_BRAKE_EMG)
                    self.auto_state = 3
                elif target_state != 3 and self.auto_state == 3:
                    pydirectinput.press(KEY_BRAKE_DOWN)
                    self.auto_state = 2
                
                if target_state != 3 and self.auto_state != 3:
                    if target_state != self.auto_state:
                        diff = target_state - self.auto_state
                        if diff > 0: 
                             for _ in range(diff): 
                                 pydirectinput.press(KEY_BRAKE_UP)
                                 time.sleep(KEY_REPEAT_DELAY)
                        elif diff < 0: 
                             for _ in range(abs(diff)): 
                                 pydirectinput.press(KEY_BRAKE_DOWN)
                                 time.sleep(KEY_REPEAT_DELAY)
                        self.auto_state = target_state
            
            else:
                if cur_b != self.prev_b:
                    if cur_b == max_brake + 1:
                        pydirectinput.press(KEY_BRAKE_EMG)
                    elif self.prev_b == max_brake + 1:
                        pydirectinput.press(KEY_BRAKE_DOWN)
                        self.prev_b = max_brake
                        diff = cur_b - self.prev_b
                        for _ in range(abs(diff)):
                            pydirectinput.press(KEY_BRAKE_DOWN)
                            time.sleep(KEY_REPEAT_DELAY)
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