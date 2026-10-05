import ctypes
import mmap
import struct
import time
from datetime import datetime, timezone

MAPPING_NAME = r"Local\CorugeTo.DenGo.VehicleSpec.v1"
SIZE = 64
MAGIC = 0x44564753
FORMAT = "<9iqiqii"
BRAKE_SYSTEMS = {0: "Unknown", 1: "Cl", 2: "Smee", 3: "Ecb"}
SYNCHRONIZE = 0x00100000
WAIT_OBJECT_0 = 0x00000000
CONTROL_EVENT_PREFIX = r"Local\CorugeTo.DenGo.VehicleSpec.Control.v1."


def read_snapshot():
    memory = mmap.mmap(-1, SIZE, tagname=MAPPING_NAME, access=mmap.ACCESS_READ)
    try:
        for _ in range(10):
            raw = memory[:SIZE]
            values = struct.unpack(FORMAT, raw)
            sequence_start = values[0]
            sequence_end = values[-1]
            if sequence_start == sequence_end and sequence_start % 2 == 0:
                return values
            time.sleep(0.005)
        raise RuntimeError("The shared-memory snapshot was changing during every read.")
    finally:
        memory.close()


def is_control_event_set(process_id, suffix):
    event_name = CONTROL_EVENT_PREFIX + str(process_id) + "." + suffix
    handle = ctypes.windll.kernel32.OpenEventW(SYNCHRONIZE, False, event_name)
    if not handle:
        return False
    try:
        return ctypes.windll.kernel32.WaitForSingleObject(handle, 0) == WAIT_OBJECT_0
    finally:
        ctypes.windll.kernel32.CloseHandle(handle)


def main():
    try:
        values = read_snapshot()
    except FileNotFoundError:
        print("Shared memory was not found. Start BVE with BveEX and the prototype extension.")
        return 2

    (sequence, magic, schema, valid, generation, brake_system, power, brake,
     holding, updated_ticks, writer_pid, _reserved64, enabled,
     sequence_end) = values

    if magic != MAGIC:
        print(f"Unexpected magic: 0x{magic:08X}")
        return 3

    unix_seconds = (updated_ticks - 621355968000000000) / 10_000_000
    updated = datetime.fromtimestamp(unix_seconds, tz=timezone.utc)
    age_ms = max(0.0, (datetime.now(timezone.utc) - updated).total_seconds() * 1000.0)
    brake_name = BRAKE_SYSTEMS.get(brake_system, f"Unknown({brake_system})")

    print(f"Sequence: {sequence}")
    print(f"SchemaVersion: {schema}")
    print(f"CallerEnabledEvent: {is_control_event_set(writer_pid, 'Enabled')}")
    print(f"BridgeReadyEvent: {is_control_event_set(writer_pid, 'Ready')}")
    print(f"SharedEnabled: {bool(enabled)}")
    print(f"Valid: {bool(valid)}")
    print(f"Generation: {generation}")
    print(f"BrakeSystem: {brake_name}")
    print(f"PowerNotchCount: {power}")
    print("BrakeNotchCount: NotApplicable" if brake_name == "Cl" else f"BrakeNotchCount: {brake}")
    print(f"HasHoldingSpeedBrake: {bool(holding)}")
    print(f"UpdatedUtc: {updated.isoformat()}")
    print(f"AgeMilliseconds: {age_ms:.1f}")
    print(f"WriterProcessId: {writer_pid}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
