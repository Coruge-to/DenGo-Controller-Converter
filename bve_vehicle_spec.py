import ctypes
import struct
import time
from dataclasses import dataclass
from typing import Optional


MAPPING_NAME = r"Local\CorugeTo.DenGo.VehicleSpec.v1"
MAPPING_SIZE = 64
MAGIC = 0x44564753
SCHEMA_VERSION = 2
SNAPSHOT_FORMAT = "<9iqiqii"
MAX_AGE_SECONDS = 1.0
BRAKE_SYSTEMS = {1: "Cl", 2: "Smee", 3: "Ecb"}
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
FILE_MAP_READ = 0x0004
SYNCHRONIZE = 0x00100000
WAIT_OBJECT_0 = 0x00000000
CONTROL_EVENT_PREFIX = r"Local\CorugeTo.DenGo.VehicleSpec.Control.v1."
CONTROLLER_MAX_POWER_NOTCH = 5
CONTROLLER_MAX_BRAKE_NOTCH = 13
kernel32 = ctypes.windll.kernel32
kernel32.OpenFileMappingW.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_wchar_p]
kernel32.OpenFileMappingW.restype = ctypes.c_void_p
kernel32.MapViewOfFile.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_size_t]
kernel32.MapViewOfFile.restype = ctypes.c_void_p
kernel32.UnmapViewOfFile.argtypes = [ctypes.c_void_p]
kernel32.UnmapViewOfFile.restype = ctypes.c_int
kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
kernel32.CloseHandle.restype = ctypes.c_int


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
        self._mapping_handle = None
        self._view_pointer = None
        self._last_valid_spec = None
        self._last_writer_process_id = None
        self._last_caller_enabled = None
        self._minimum_fresh_utc_ticks = None

    def close(self):
        self.disconnect()
        self._last_valid_spec = None
        self._last_writer_process_id = None
        self._last_caller_enabled = None
        self._minimum_fresh_utc_ticks = None

    def disconnect(self):
        if self._view_pointer:
            kernel32.UnmapViewOfFile(ctypes.c_void_p(self._view_pointer))
            self._view_pointer = None
        if self._mapping_handle:
            kernel32.CloseHandle(ctypes.c_void_p(self._mapping_handle))
            self._mapping_handle = None
        self._clear_cache()
        self._last_caller_enabled = None
        self._minimum_fresh_utc_ticks = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()

    def _open_if_needed(self):
        if self._view_pointer: return True
        h=kernel32.OpenFileMappingW(FILE_MAP_READ, False, MAPPING_NAME)
        if not h:return False
        p=kernel32.MapViewOfFile(ctypes.c_void_p(h), FILE_MAP_READ, 0, 0, MAPPING_SIZE)
        if not p:
            kernel32.CloseHandle(ctypes.c_void_p(h))
            return False
        self._mapping_handle=h;self._view_pointer=p;return True
    def _read_consistent_values(self):
        if not self._open_if_needed(): return None
        for _ in range(4):
            raw=ctypes.string_at(self._view_pointer,MAPPING_SIZE)
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
            source_enabled,
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
            self._last_caller_enabled = None
            self._minimum_fresh_utc_ticks = None
            return None

        caller_enabled = self._is_control_event_set(writer_process_id, "Enabled")
        if not caller_enabled:
            self._clear_cache()
            self._last_caller_enabled = False
            self._minimum_fresh_utc_ticks = self._current_utc_ticks()
            return None

        if self._last_caller_enabled is False:
            self._minimum_fresh_utc_ticks = self._current_utc_ticks()
        self._last_caller_enabled = True

        if not self._is_control_event_set(writer_process_id, "Ready"):
            return None

        if not source_enabled:
            return None

        if (
            self._minimum_fresh_utc_ticks is not None
            and updated_utc_ticks <= self._minimum_fresh_utc_ticks
        ):
            return None
        self._minimum_fresh_utc_ticks = None

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
    def _is_control_event_set(process_id, suffix):
        if not process_id or process_id <= 0:
            return False
        event_name = CONTROL_EVENT_PREFIX + str(process_id) + "." + suffix
        handle = ctypes.windll.kernel32.OpenEventW(SYNCHRONIZE, False, event_name)
        if not handle:
            return False
        try:
            return ctypes.windll.kernel32.WaitForSingleObject(handle, 0) == WAIT_OBJECT_0
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)

    @staticmethod
    def _current_utc_ticks():
        return int(time.time() * 10000000.0) + 621355968000000000

    @staticmethod
    def _calculate_age_seconds(updated_utc_ticks):
        unix_ticks = updated_utc_ticks - 621355968000000000
        updated_unix_seconds = unix_ticks / 10000000.0
        return time.time() - updated_unix_seconds
