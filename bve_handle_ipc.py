"""Versioned shared-memory contract for DenGo BVE handle commands.

The Python process publishes brake-priority logical commands. The BVE Input
Device DLL decides whether to use the one-handle axis or the separate power and
brake axes. No handle-layout information is carried by this contract.
"""

from dataclasses import dataclass
import ctypes
import mmap
import os
import struct
import time
from typing import Optional

from bve_handle_command import (
    BRAKE_MODE_AUTOMATIC_AIR,
    BRAKE_MODE_ELECTRIC,
    BveHandleCommand,
)

MAPPING_NAME = r"Local\CorugeTo.DenGo.HandleCommand.v1"
PUBLISHER_MUTEX_NAME = r"Local\CorugeTo.DenGo.HandleCommand.Publisher.v1"
ERROR_ALREADY_EXISTS = 183
MAPPING_SIZE = 64
MAGIC = 0x44474843  # "DGHC"
SCHEMA_VERSION = 1
SNAPSHOT_FORMAT = "<12iq2i"
SNAPSHOT_SIZE = struct.calcsize(SNAPSHOT_FORMAT)

if SNAPSHOT_SIZE != MAPPING_SIZE:
    raise RuntimeError(
        f"Handle-command snapshot size mismatch: {SNAPSHOT_SIZE} != {MAPPING_SIZE}"
    )

BRAKE_MODE_VALUES = {
    BRAKE_MODE_ELECTRIC: 1,
    BRAKE_MODE_AUTOMATIC_AIR: 2,
}


@dataclass(frozen=True)
class BveHandleSnapshot:
    sequence: int
    publisher_process_id: int
    generation: int
    enabled: bool
    valid: bool
    brake_mode: int
    power_notch: int
    service_brake_notch: int
    emergency: bool
    auto_brake_position: int
    updated_utc_ticks: int


def current_utc_ticks() -> int:
    return int(time.time() * 10_000_000.0) + 621355968000000000


def pack_snapshot(snapshot: BveHandleSnapshot) -> bytes:
    if snapshot.sequence < 0 or snapshot.sequence % 2 != 0:
        raise ValueError("Committed sequence must be a non-negative even value")
    _validate_snapshot(snapshot)
    return struct.pack(
        SNAPSHOT_FORMAT,
        snapshot.sequence,
        MAGIC,
        SCHEMA_VERSION,
        snapshot.publisher_process_id,
        snapshot.generation,
        int(snapshot.enabled),
        int(snapshot.valid),
        snapshot.brake_mode,
        snapshot.power_notch,
        snapshot.service_brake_notch,
        int(snapshot.emergency),
        snapshot.auto_brake_position,
        snapshot.updated_utc_ticks,
        0,
        snapshot.sequence,
    )


def unpack_snapshot(data: bytes) -> Optional[BveHandleSnapshot]:
    if len(data) < SNAPSHOT_SIZE:
        return None
    values = struct.unpack(SNAPSHOT_FORMAT, data[:SNAPSHOT_SIZE])
    (
        sequence_start,
        magic,
        schema_version,
        publisher_process_id,
        generation,
        enabled,
        valid,
        brake_mode,
        power_notch,
        service_brake_notch,
        emergency,
        auto_brake_position,
        updated_utc_ticks,
        _reserved,
        sequence_end,
    ) = values
    if sequence_start != sequence_end or sequence_start % 2 != 0:
        return None
    if magic != MAGIC or schema_version != SCHEMA_VERSION:
        return None
    snapshot = BveHandleSnapshot(
        sequence=sequence_start,
        publisher_process_id=publisher_process_id,
        generation=generation,
        enabled=bool(enabled),
        valid=bool(valid),
        brake_mode=brake_mode,
        power_notch=power_notch,
        service_brake_notch=service_brake_notch,
        emergency=bool(emergency),
        auto_brake_position=auto_brake_position,
        updated_utc_ticks=updated_utc_ticks,
    )
    try:
        _validate_snapshot(snapshot)
    except ValueError:
        return None
    return snapshot


class BveHandleCommandPublisher:
    def __init__(self, mapping_name: str = MAPPING_NAME):
        if os.name != "nt":
            raise RuntimeError("Named BVE handle-command mapping requires Windows")
        self.mapping_name = mapping_name
        self._mapping = mmap.mmap(-1, MAPPING_SIZE, tagname=mapping_name)
        self._sequence = 0
        self.publish_disabled(generation=0)

    def publish_command(
        self,
        command: BveHandleCommand,
        generation: int,
        enabled: bool,
        valid: bool,
    ) -> BveHandleSnapshot:
        brake_mode = BRAKE_MODE_VALUES.get(command.brake_mode)
        if brake_mode is None:
            raise ValueError(f"Unsupported brake mode: {command.brake_mode!r}")
        snapshot = BveHandleSnapshot(
            sequence=self._next_sequence(),
            publisher_process_id=os.getpid(),
            generation=generation,
            enabled=enabled,
            valid=valid,
            brake_mode=brake_mode,
            power_notch=command.power_notch,
            service_brake_notch=command.service_brake_notch,
            emergency=command.emergency,
            auto_brake_position=command.auto_brake_position,
            updated_utc_ticks=current_utc_ticks(),
        )
        self._write_snapshot(snapshot)
        return snapshot

    def publish_disabled(self, generation: int) -> BveHandleSnapshot:
        snapshot = BveHandleSnapshot(
            sequence=self._next_sequence(),
            publisher_process_id=os.getpid(),
            generation=generation,
            enabled=False,
            valid=False,
            brake_mode=0,
            power_notch=0,
            service_brake_notch=0,
            emergency=False,
            auto_brake_position=0,
            updated_utc_ticks=current_utc_ticks(),
        )
        self._write_snapshot(snapshot)
        return snapshot

    def close(self) -> None:
        mapping = self._mapping
        if mapping is None:
            return
        try:
            self.publish_disabled(generation=0)
        finally:
            mapping.close()
            self._mapping = None
            mutex_handle = self._mutex_handle
            self._mutex_handle = None
            if mutex_handle:
                kernel32 = ctypes.windll.kernel32
                kernel32.ReleaseMutex(ctypes.c_void_p(mutex_handle))
                kernel32.CloseHandle(ctypes.c_void_p(mutex_handle))

    def _next_sequence(self) -> int:
        self._sequence += 2
        if self._sequence > 0x7FFFFFFE:
            self._sequence = 2
        return self._sequence

    def _write_snapshot(self, snapshot: BveHandleSnapshot) -> None:
        if self._mapping is None:
            raise RuntimeError("Publisher is closed")
        odd_sequence = snapshot.sequence - 1
        data = bytearray(pack_snapshot(snapshot))
        struct.pack_into("<i", data, 0, odd_sequence)
        struct.pack_into("<i", data, MAPPING_SIZE - 4, odd_sequence)
        self._mapping.seek(0)
        self._mapping.write(data)
        self._mapping.seek(0)
        self._mapping.write(pack_snapshot(snapshot))
        self._mapping.flush()


def _validate_snapshot(snapshot: BveHandleSnapshot) -> None:
    if snapshot.publisher_process_id < 0:
        raise ValueError("publisher_process_id must not be negative")
    if snapshot.generation < 0:
        raise ValueError("generation must not be negative")
    if snapshot.brake_mode not in (0, 1, 2):
        raise ValueError("brake_mode must be 0, 1, or 2")
    if snapshot.power_notch < 0:
        raise ValueError("power_notch must not be negative")
    if snapshot.service_brake_notch < 0:
        raise ValueError("service_brake_notch must not be negative")
    if not 0 <= snapshot.auto_brake_position <= 3:
        raise ValueError("auto_brake_position must be between 0 and 3")
    if snapshot.updated_utc_ticks < 0:
        raise ValueError("updated_utc_ticks must not be negative")
    if snapshot.valid and not snapshot.enabled:
        raise ValueError("valid snapshot must also be enabled")
    if not snapshot.valid:
        return
    if snapshot.brake_mode == 0:
        raise ValueError("valid snapshot must specify a brake mode")
    if snapshot.brake_mode == 1:
        if snapshot.auto_brake_position != 0:
            raise ValueError("electric command must not use auto_brake_position")
        active = sum(
            (
                snapshot.power_notch > 0,
                snapshot.service_brake_notch > 0,
                snapshot.emergency,
            )
        )
        if active > 1:
            raise ValueError("electric command inputs must be mutually exclusive")
    if snapshot.brake_mode == 2:
        if snapshot.service_brake_notch != 0:
            raise ValueError("automatic-air command must not use service notch")
        if snapshot.emergency != (snapshot.auto_brake_position == 3):
            raise ValueError("automatic-air emergency flag is inconsistent")
        if snapshot.auto_brake_position != 0 and snapshot.power_notch != 0:
            raise ValueError("automatic-air brake must take priority over power")
