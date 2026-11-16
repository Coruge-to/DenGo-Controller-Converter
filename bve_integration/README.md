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

## Handle resync after a BVE vehicle reset

When BVE itself resets the vehicle (station jump, scenario reload, F5) the handle is set to its initial value and no longer matches the physical controller. The VehicleSpec plugins count these resets and the Caller re-sends the controller's current value once.

- `shared/ResetHook.cs` (linked into both VehicleSpec plugins): a Harmony Postfix on the BVE-internal `Vehicle.Initialize(BrakePosition)` increments a counter, which the plugin publishes as an 8-byte value in the previously reserved field at offset 48 of the `Local\CorugeTo.DenGo.VehicleSpec.v1` mapping (schema version unchanged; Python ignores the field). All references to 0Harmony are confined to one nested class; if 0Harmony or the BVE method cannot be resolved a single `RESET_HOOK disabled reason=...` line is written to `DenGoControllerConverter.log` and the product behaves as before.
- `shared/StallPulse.cs`: while the extension Tick is stalled (Pause) for 80 ms or more, a 16 ms pulse posts a read-only snapshot refresh to the UI thread so the Caller/Python keep trusting the snapshot and a reset during Pause is re-sent immediately.
- `caller/CallerInputDevice.cs`: reads the counter from the VehicleSpec mapping on every Tick (level-triggered; the publisher process id must match), and when it changed bypasses the same-value suppression for exactly one send (`LEVER_MOVED ... resync=vehicle-reset`). The request is kept until a send really happens.
- Build: both plugin projects reference the host's `0Harmony.dll` (`lib\0Harmony.dll`, local and untracked like the other `lib` references; `Private=False`): BveEX 2.0 `0Harmony 2.3.3` for the Current plugin, AtsEX/BveEX Legacy `0Harmony 2.2.2` for the Legacy plugin. The runtime uses the copy bundled with the host.
- Evidence: observer and prototype runs in `DenGo-Claude-Handoff\bve-handle-resync-harmony-probe-v3` (findings and design-H documents).