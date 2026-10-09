"""Pure BVE handle-command resolution for DenGo.

This module deliberately knows nothing about BVE one-handle/two-handle axes.
It converts the physical two-handle controller into a brake-priority logical
command. A single BVE Input Device DLL is responsible for mapping that logical
command to the vehicle's axis layout.
"""

from dataclasses import dataclass

BRAKE_MODE_ELECTRIC = "1"  # Ecb / Smee
BRAKE_MODE_AUTOMATIC_AIR = "2"  # Cl

AUTO_BRAKE_RELEASE = 0
AUTO_BRAKE_LAP = 1
AUTO_BRAKE_SERVICE = 2
AUTO_BRAKE_EMERGENCY = 3

CONTROLLER_EMERGENCY_POSITION = 14
CONTROLLER_MAX_SERVICE_BRAKE_POSITION = 13


@dataclass(frozen=True)
class BveHandleCommand:
    brake_mode: str
    power_notch: int
    service_brake_notch: int
    emergency: bool
    auto_brake_position: int


def convert_automatic_air_brake(raw_brake: int) -> int:
    """Map the physical 0..14 brake range onto Cl positions.

    0..7  = release
    8     = lap
    9..13 = service
    14    = emergency
    """
    _validate_raw_brake(raw_brake)
    if raw_brake <= 7:
        return AUTO_BRAKE_RELEASE
    if raw_brake == 8:
        return AUTO_BRAKE_LAP
    if raw_brake <= CONTROLLER_MAX_SERVICE_BRAKE_POSITION:
        return AUTO_BRAKE_SERVICE
    return AUTO_BRAKE_EMERGENCY


def resolve_bve_handle_command(
    raw_power: int,
    raw_brake: int,
    brake_mode: str,
    max_power: int,
    max_brake: int,
) -> BveHandleCommand:
    """Resolve physical two-handle input into a brake-priority command."""
    if brake_mode not in (BRAKE_MODE_ELECTRIC, BRAKE_MODE_AUTOMATIC_AIR):
        raise ValueError(f"Unsupported brake mode: {brake_mode!r}")
    if max_power < 0:
        raise ValueError("max_power must not be negative")
    if max_brake < 0:
        raise ValueError("max_brake must not be negative")
    if raw_power < 0:
        raise ValueError("raw_power must not be negative")
    _validate_raw_brake(raw_brake)

    clamped_power = min(raw_power, max_power)

    if brake_mode == BRAKE_MODE_ELECTRIC:
        if raw_brake == CONTROLLER_EMERGENCY_POSITION:
            return BveHandleCommand(
                brake_mode=brake_mode,
                power_notch=0,
                service_brake_notch=0,
                emergency=True,
                auto_brake_position=AUTO_BRAKE_RELEASE,
            )
        if raw_brake > 0:
            return BveHandleCommand(
                brake_mode=brake_mode,
                power_notch=0,
                service_brake_notch=min(raw_brake, max_brake),
                emergency=False,
                auto_brake_position=AUTO_BRAKE_RELEASE,
            )
        return BveHandleCommand(
            brake_mode=brake_mode,
            power_notch=clamped_power,
            service_brake_notch=0,
            emergency=False,
            auto_brake_position=AUTO_BRAKE_RELEASE,
        )

    auto_position = convert_automatic_air_brake(raw_brake)
    return BveHandleCommand(
        brake_mode=brake_mode,
        power_notch=(
            clamped_power if auto_position == AUTO_BRAKE_RELEASE else 0
        ),
        service_brake_notch=0,
        emergency=(auto_position == AUTO_BRAKE_EMERGENCY),
        auto_brake_position=auto_position,
    )


def _validate_raw_brake(raw_brake: int) -> None:
    if not 0 <= raw_brake <= CONTROLLER_EMERGENCY_POSITION:
        raise ValueError(
            "raw_brake must be between 0 and "
            f"{CONTROLLER_EMERGENCY_POSITION}"
        )
