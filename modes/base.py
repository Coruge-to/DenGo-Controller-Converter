# modes/base.py
class BaseLogic:
    def __init__(self):
        self.prev_p = 0
        self.prev_b = 0
        # ボタン状態管理
        self.p_start = False
        self.p_select = False
        self.needs_sync = True

    def reset(self):
        """状態を強制リセットする時に呼ぶ"""
        self.prev_p = 0
        self.prev_b = 0
        self.needs_sync = True # リセット時に同期フラグを立てる

    def update(self, cur_p, cur_b, raw_btns, context):
        pass