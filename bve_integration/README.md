# BVE integration

This directory contains the source for the BVE input-device Caller, the BveEX handshake Bridge, and the VehicleSpec Extension.

Control flow:

1. Caller publishes Enabled and Stop events per BVE process ID.
2. Bridge observes the events on a background thread and publishes BridgeAvailable and Ready without depending on BVE simulation Tick.
3. VehicleSpec reads BVE vehicle information only on the BveEX Tick thread and writes schema-v2 shared memory.
4. Python treats Caller Enabled as authoritative for OFF and waits for a fresh snapshot after re-enabling.

Local third-party DLL references, bin, and obj are intentionally excluded from Git.
Public artifacts must use Coruge-to as the provider name.
