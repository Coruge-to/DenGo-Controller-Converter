# modes/bve.py
from .base import BaseLogic


class BveLogic(BaseLogic):
    """BVE-specific controller button state.

    Handle positions and START/SELECT states are published through the BVE
    Input Device shared-memory path. This class never emits global keyboard
    input.
    """

    START_BUTTON_MASK = 0x01
    SELECT_BUTTON_MASK = 0x02

    @property
    def button_mask(self):
        mask = 0
        if self.p_start:
            mask |= self.START_BUTTON_MASK
        if self.p_select:
            mask |= self.SELECT_BUTTON_MASK
        return mask

    def reset(self):
        super().reset()

    def update_buttons(self, raw_btns):
        self.p_start = raw_btns[9] == 1
        self.p_select = raw_btns[10] == 1
