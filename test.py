import pygame
pygame.init()
pygame.joystick.init()
joy = pygame.joystick.Joystick(0)
joy.init()

while True:
    pygame.event.pump()
    # 全軸の値を表示して、B8〜非常で動く軸を探す
    axes = [joy.get_axis(i) for i in range(joy.get_numaxes())]
    # 全ボタンの状態を表示して、非常位置でTrueになる番号を探す
    buttons = [joy.get_button(i) for i in range(joy.get_numbuttons())]
    print(f"Axes: {axes} Buttons: {buttons}", end="\r")