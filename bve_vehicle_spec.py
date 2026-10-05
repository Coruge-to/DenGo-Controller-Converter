import ctypes
import mmap
import struct
import time
from dataclasses import dataclass
from typing import Optional


MAPPING_NAME = r"Local\CorugeTo.DenGo.VehicleSpec.v1"
MAPPING_SIZE = 64
MAGIC = 0x44564753
SCHEMA_VERSION = 1
SNAPSHOT_FORMAT = "<9iqiqii"
MAX_AGE_SECONDS = 1.0
BRAKE_SYSTEMS = {1: "Cl", 2: "Smee", 3: "Ecb"}
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
CONTROLLER_MAX_POWER_NOTCH = 5
CONTROLLER_MAX_BRAKE_NOTCH = 13


@dataclass(frozen=True)
class BveVehicleSpec:
    valid: bool
    generation: int
    brake_system: str
    power_notch_count: int
    brake_notch_count: Optional[int]
    has_holding_speed_brake: bool
    age_seconds: float
    writer_process_id: int


class BveVehicleSpecReceiver:
    def __init__(self, max_age_seconds=MAX_AGE_SECONDS):
        self.max_age_seconds = float(max_age_seconds)
        self._memory = None
        self._last_valid_spec = None
        self._last_writer_process_id = None

    def close(self):
        if self._memory is not None:
            try:
                self._memory.close()
            finally:
                self._memory = None
        self._last_valid_spec = None
        self._last_writer_process_id = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()

    def _open_if_needed(self):
        if self._memory is None:
            self._memory = mmap.mmap(
                -1,
                MAPPING_SIZE,
                tagname=MAPPING_NAME,
                access=mmap.ACCESS_READ,
            )

    def _read_consistent_values(self):
        self._open_if_needed()
        for _ in range(4):
            raw = self._memory[:MAPPING_SIZE]
            values = struct.unpack(SNAPSHOT_FORMAT, raw)
            sequence_start = values[0]
            sequence_end = values[-1]
            if sequence_start == sequence_end and sequence_start % 2 == 0:
                return values
        return None

    def read(self):
        try:
            values = self._read_consistent_values()
        except (FileNotFoundError, OSError, ValueError):
            self.close()
            return None

        if values is None:
            return self._get_cached_spec_if_writer_is_alive()

        (
            _sequence,
            magic,
            schema_version,
            source_valid,
            generation,
            brake_system_value,
            power_notch_count,
            brake_notch_count,
            has_holding_speed_brake,
            updated_utc_ticks,
            writer_process_id,
            _reserved_64,
            _reserved_32,
            _sequence_end,
        ) = values

        if magic != MAGIC or schema_version != SCHEMA_VERSION:
            self._clear_cache()
            return None

        if writer_process_id != self._last_writer_process_id:
            self._last_valid_spec = None
            self._last_writer_process_id = writer_process_id

        if not self._is_process_alive(writer_process_id):
            self._clear_cache()
            return None

        age_seconds = self._calculate_age_seconds(updated_utc_ticks)
        if not source_valid:
            return self._last_valid_spec

        brake_system = BRAKE_SYSTEMS.get(brake_system_value)
        if brake_system is None:
            return self._last_valid_spec
        if age_seconds < 0.0 or age_seconds > self.max_age_seconds:
            return self._last_valid_spec
        if not 1 <= power_notch_count <= 20:
            return self._last_valid_spec

        if brake_system == "Cl":
            effective_brake_count = None
            effective_holding = False
        else:
            if not 1 <= brake_notch_count <= 30:
                return self._last_valid_spec
            effective_brake_count = brake_notch_count
            effective_holding = bool(has_holding_speed_brake)

        current_spec = BveVehicleSpec(
            valid=True,
            generation=generation,
            brake_system=brake_system,
            power_notch_count=min(power_notch_count, CONTROLLER_MAX_POWER_NOTCH),
            brake_notch_count=(
                None
                if effective_brake_count is None
                else min(effective_brake_count, CONTROLLER_MAX_BRAKE_NOTCH)
            ),
            has_holding_speed_brake=effective_holding,
            age_seconds=age_seconds,
            writer_process_id=writer_process_id,
        )
        self._last_valid_spec = current_spec
        return current_spec

    def _get_cached_spec_if_writer_is_alive(self):
        if self._last_valid_spec is None:
            return None
        if not self._is_process_alive(self._last_writer_process_id):
            self._clear_cache()
            return None
        return self._last_valid_spec

    def _clear_cache(self):
        self._last_valid_spec = None
        self._last_writer_process_id = None

    @staticmethod
    def _is_process_alive(process_id):
        if not process_id or process_id <= 0:
            return False
        handle = ctypes.windll.kernel32.OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION,
            False,
            process_id,
        )
        if not handle:
            return False
        ctypes.windll.kernel32.CloseHandle(handle)
        return True

    @staticmethod
    def _calculate_age_seconds(updated_utc_ticks):
        unix_ticks = updated_utc_ticks - 621355968000000000
        updated_unix_seconds = unix_ticks / 10000000.0
        return time.time() - updated_unix_seconds
