# Emulator input profiles

These files are installer source assets for DenGo Controller Converter.
The installer/build directory is generated output and is not the source of truth.

## PCSX2

- Install DenGo-Controller-Converter.lily only when a compatible LilyPad environment is detected.
- Do not create PCSX2 directories when PCSX2 is not detected.
- Do not replace LilyPad.ini as a whole.
- Preserve a user-modified profile when its SHA-256 differs from the shipped profile.
- Pad 1 contains verified keyboard and XInput mappings. Pad 2 is intentionally unassigned.

## RPCS3

- Install Den-Go-Controller.yml only when a compatible input_configs directory is detected.
- Do not create RPCS3 directories when RPCS3 is not detected.
- Never overwrite Default.yml.
- Preserve a user-modified Den-Go-Controller.yml when its SHA-256 differs from the shipped profile.
- Profile selection may require one manual action in RPCS3.

## Re-running the installer

- Add files for newly detected platforms.
- Leave identical files unchanged.
- Repair missing shipped files.
- Do not automatically delete files for platforms that are temporarily not detected.
