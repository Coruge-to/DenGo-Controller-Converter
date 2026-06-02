# modes/running_train.py
import pydirectinput
from const import *
from .base import BaseLogic

class RunningLogic(BaseLogic):
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
        cur_b = 0
        if brake_mode == "1":
            if raw_b == 14: cur_b = max_brake + 1
            elif raw_b == 0: cur_b = 0
            else: cur_b = min(raw_b, max_brake)
        else:
            cur_b = raw_b
            
        # --- 初回同期処理 ---
        if self.needs_sync:
            self.prev_p = cur_p
            self.prev_b = cur_b
            
            # 自動空気ブレーキの位置判定
            if brake_mode == "2":
                self.auto_state = cur_b
            
            self.needs_sync = False
            return
        # ---------------------------

        if cur_b <= 0:
            if brake_mode == "2":
                target_state = 0
                if self.auto_state != 0:
                    # ★変更: 連打を廃止し「ブレーキ切(m)」を一発送信
                    pydirectinput.press('m')
                    self.auto_state = 0
            
            if brake_mode == "1" and self.prev_b > 0:
                # ★変更: 連打を廃止し「ブレーキ切(m)」を一発送信
                pydirectinput.press('m')
                self.prev_b = 0

            if cur_p != self.prev_p:
                if cur_p == 0:
                    # ★変更: 連打を廃止し「マスコン切(q)」を一発送信
                    pydirectinput.press('q')
                else:
                    diff = cur_p - self.prev_p
                    if diff > 0:
                        for _ in range(diff): 
                            pydirectinput.press(KEY_MASCON_UP)
                    elif diff < 0:
                        for _ in range(abs(diff)): 
                            pydirectinput.press(KEY_MASCON_DOWN)
                self.prev_p = cur_p

        else:
            if self.prev_p != 0:
                # ★変更: ブレーキ作動時の強制ノッチオフも「マスコン切(q)」を一発送信
                pydirectinput.press('q')
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
                        elif diff < 0: 
                             for _ in range(abs(diff)): 
                                 pydirectinput.press(KEY_BRAKE_DOWN)
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
                    else:
                        diff = cur_b - self.prev_b
                        key = KEY_BRAKE_UP if diff > 0 else KEY_BRAKE_DOWN
                        for _ in range(abs(diff)):
                            pydirectinput.press(key)
                    self.prev_b = cur_b

        is_st, is_sl = (raw_btns[9]==1), (raw_btns[10]==1)
        if is_st != self.p_start: 
            pydirectinput.keyDown('h') if is_st else pydirectinput.keyUp('h')
            self.p_start = is_st
        if is_sl != self.p_select: 
            pydirectinput.keyDown('space') if is_sl else pydirectinput.keyUp('space')
            self.p_select = is_sl