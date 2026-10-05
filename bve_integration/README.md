# BVE integration

This directory contains the source for the BVE input-device Caller, the BveEX handshake Bridge, and the VehicleSpec Extension.

Control flow:

1. Caller publishes Enabled and Stop events per BVE process ID.
2. Bridge observes the events on a background thread and publishes BridgeAvailable and Ready without depending on BVE simulation Tick.
3. VehicleSpec reads BVE vehicle information only on the BveEX Tick thread and writes schema-v2 shared memory.
4. Python treats Caller Enabled as authoritative for OFF and waits for a fresh snapshot after re-enabling.

Local third-party DLL references, bin, and obj are intentionally excluded from Git.
Public artifacts must use Coruge-to as the provider name.

## Verified environments

- BVE Trainsim 6: Ecb and Smee vehicle specifications, notch counts, holding-speed brake state, scenario changes, and pause-independent Caller/Bridge control were verified on actual scenarios.
- BVE Trainsim 5: Cl, Smee, and Ecb vehicle specifications were verified on actual scenarios. Disabling the DenGo input device correctly returned the converter to its initial 5-power/8-brake state.
- BveEX legacy mode for AtsEX-compatible vehicles is not yet supported or verified. Treat this as a separate compatibility investigation because legacy loading, namespaces, assemblies, and lifecycle contracts may differ from current BveEX mode.

## AtsEX legacy compatibility

AtsEX legacy compatibility, verification results, and the TS Scoring handoff boundary are documented in `docs/legacy-compatibility.md`.
