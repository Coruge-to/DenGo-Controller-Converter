# modes/bve.py
import pydirectinput

from const import KEY_SELECT, KEY_START_BVE
from .base import BaseLogic


class BveLogic(BaseLogic):
    """BVE-specific controller button output.

    Handle positions are published through the absolute Axis 3 IPC path.
    This class owns only START and SELECT key state.
    """

    def reset(self):
        if self.p_start:
            pydirectinput.keyUp(KEY_START_BVE)
        if self.p_select:
            pydirectinput.keyUp(KEY_SELECT)
        super().reset()

    def update_buttons(self, raw_btns):
        is_start = raw_btns[9] == 1
        is_select = raw_btns[10] == 1

        if is_start != self.p_start:
            if is_start:
                pydirectinput.keyDown(KEY_START_BVE)
            else:
                pydirectinput.keyUp(KEY_START_BVE)
            self.p_start = is_start

        if is_select != self.p_select:
            if is_select:
                pydirectinput.keyDown(KEY_SELECT)
            else:
                pydirectinput.keyUp(KEY_SELECT)
            self.p_select = is_select
