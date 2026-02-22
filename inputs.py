# inputs.py
import time
import pygame
from const import N_WAIT_TIME

class StableNotchReader:
    """ノッチ入力のチャタリングを防ぎ、値が安定するまで待つクラス"""
    def __init__(self, init_val=0):
        self.last_raw = init_val
        self.start_time = time.time()
        self.confirmed = init_val

    def update(self, raw_val):
        now = time.time()
        # 未定義(-1)の場合は直前の確定値を維持
        if raw_val == -1:
            return self.confirmed
        
        # N位置(0)に戻る時は少し長めに待つ(誤検知防止)、それ以外は短く    
        if raw_val != self.last_raw:
            self.start_time = now
            self.last_raw = raw_val
            return self.confirmed
        
        if (now - self.start_time) > N_WAIT_TIME:
            self.confirmed = raw_val
            return raw_val
        
        return self.confirmed

def get_inputs(joy):
    """
    ジョイスティックから入力を取得し、ビットパターンに変換する
    joy: pygame.joystick.Joystick オブジェクト
    戻り値: (b_val, p_pat, btns)
    """
    pygame.event.pump()
    if joy is None:
        return 0, (0,0,0), [0]*17
    
    raw = [joy.get_button(i) for i in range(16)]
    btns = [None] + raw # 1-based indexに合わせるためのダミー
    
    # 電車でGO!コントローラー特有のビット演算
    b_val = (btns[6]<<3) | (btns[8]<<2) | (btns[5]<<1) | btns[7]
    p_pat = (btns[14], btns[16], btns[1])
    
    return b_val, p_pat, btns