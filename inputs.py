# inputs.py
import pygame

class StableNotchReader:
    """無効な入力(-1)を無視し、有効な値だけを即時反映するクラス"""
    def __init__(self, init_val=0):
        self.confirmed = init_val

    def update(self, raw_val):
        # 未定義(-1)の場合は直前の確定値を維持
        if raw_val == -1:
            return self.confirmed
        
        # それ以外の有効な値は、即座に確定させる
        self.confirmed = raw_val
        return raw_val

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