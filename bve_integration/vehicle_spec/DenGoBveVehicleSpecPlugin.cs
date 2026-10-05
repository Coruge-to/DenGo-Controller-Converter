using System;
using System.IO.MemoryMappedFiles;
using System.Reflection;
using System.Diagnostics;
using System.Threading;
using BveEx.PluginHost;
using BveEx.PluginHost.Plugins;
using BveEx.PluginHost.Plugins.Extensions;

namespace DenGoBveVehicleSpec
{
    [Plugin(PluginType.Extension)]
    public sealed class DenGoBveVehicleSpecPlugin : AssemblyPluginBase, IExtension
    {
        private const string MappingName = "Local\\CorugeTo.DenGo.VehicleSpec.v1";
        private const int MappingSize = 64;
        private const int Magic = 0x44564753; // DVGS
        private const int SchemaVersion = 2;
        private const string ControlPrefix = @"Local\CorugeTo.DenGo.VehicleSpec.Control.v1.";
        private const BindingFlags All = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;

        private readonly MemoryMappedFile mapping;
        private readonly MemoryMappedViewAccessor view;
        private object currentScenario;
        private int generation;
        private int sequence;
        private bool disposed;
        private EventWaitHandle ready;
        private int lastReadyPoll;
        private bool controlEnabled;

        public DenGoBveVehicleSpecPlugin(PluginBuilder builder) : base(builder)
        {
            mapping = MemoryMappedFile.CreateOrOpen(MappingName, MappingSize, MemoryMappedFileAccess.ReadWrite);
            view = mapping.CreateViewAccessor(0, MappingSize, MemoryMappedFileAccess.ReadWrite);
            PublishInvalid();
        }

        public override void Tick(TimeSpan elapsed)
        {
            try
            {
                UpdateControlState();
                if (!controlEnabled)
                {
                    PublishRaw(false, BrakeSystemKind.Unknown, 0, 0, false, false);
                    return;
                }
                if (!BveHacker.IsScenarioCreated)
                {
                    if (currentScenario != null)
                    {
                        currentScenario = null;
                        generation++;
                    }
                    PublishInvalid();
                    return;
                }

                object scenario = BveHacker.Scenario;
                if (!object.ReferenceEquals(currentScenario, scenario))
                {
                    currentScenario = scenario;
                    generation++;
                }

                VehicleSpec spec;
                if (TryReadVehicleSpec(scenario, out spec))
                {
                    Publish(spec);
                }
                else
                {
                    PublishInvalid();
                }
            }
            catch
            {
                PublishInvalidNoThrow();
            }
        }

        public override void Dispose()
        {
            if (disposed) return;
            disposed = true;
            PublishInvalidNoThrow();
            if (ready != null) ready.Dispose();
            view.Dispose();
            mapping.Dispose();
        }

        private static bool TryReadVehicleSpec(object scenario, out VehicleSpec spec)
        {
            spec = new VehicleSpec();
            object vehicle = GetRequiredProperty(scenario, "Vehicle");
            object instruments = GetRequiredProperty(vehicle, "Instruments");
            object cab = GetRequiredProperty(instruments, "Cab");
            object handles = GetRequiredProperty(cab, "Handles");
            object notchInfo = GetRequiredProperty(handles, "NotchInfo");

            int powerNotchCount = Convert.ToInt32(GetRequiredProperty(notchInfo, "PowerNotchCount"));
            int brakeNotchCount = Convert.ToInt32(GetRequiredProperty(notchInfo, "BrakeNotchCount"));
            bool hasHolding = Convert.ToBoolean(GetRequiredProperty(notchInfo, "HasHoldingSpeedBrake"));

            object brakeSystem = GetRequiredProperty(instruments, "BrakeSystem");
            object controller = GetRequiredProperty(brakeSystem, "BrakeController");
            BrakeSystemKind kind = DetectBrakeSystem(brakeSystem, controller);

            if (kind == BrakeSystemKind.Unknown) return false;
            if (powerNotchCount < 1 || powerNotchCount > 20) return false;
            if (kind != BrakeSystemKind.Cl && (brakeNotchCount < 1 || brakeNotchCount > 30)) return false;

            if (kind == BrakeSystemKind.Cl)
            {
                brakeNotchCount = 0;
                hasHolding = false;
            }

            spec.BrakeSystem = kind;
            spec.PowerNotchCount = powerNotchCount;
            spec.BrakeNotchCount = brakeNotchCount;
            spec.HasHoldingSpeedBrake = hasHolding;
            return true;
        }

        private static BrakeSystemKind DetectBrakeSystem(object brakeSystem, object controller)
        {
            object ecb = TryGetProperty(brakeSystem, "Ecb");
            object smee = TryGetProperty(brakeSystem, "Smee");
            object cl = TryGetProperty(brakeSystem, "Cl");

            if (SameSource(controller, ecb)) return BrakeSystemKind.Ecb;
            if (SameSource(controller, smee)) return BrakeSystemKind.Smee;
            if (SameSource(controller, cl)) return BrakeSystemKind.Cl;

            string typeName = controller == null ? string.Empty : controller.GetType().Name;
            if (typeName.IndexOf("AutomaticAir", StringComparison.OrdinalIgnoreCase) >= 0 ||
                typeName.IndexOf("Cl", StringComparison.OrdinalIgnoreCase) >= 0) return BrakeSystemKind.Cl;
            if (typeName.IndexOf("Electromagnetic", StringComparison.OrdinalIgnoreCase) >= 0 ||
                typeName.IndexOf("Smee", StringComparison.OrdinalIgnoreCase) >= 0) return BrakeSystemKind.Smee;
            if (typeName.IndexOf("Ecb", StringComparison.OrdinalIgnoreCase) >= 0) return BrakeSystemKind.Ecb;
            return BrakeSystemKind.Unknown;
        }

        private static bool SameSource(object controller, object candidate)
        {
            if (controller == null || candidate == null) return false;
            object controllerSource = TryGetProperty(controller, "Src") ?? controller;
            object candidateSource = TryGetProperty(candidate, "Src") ?? candidate;
            return object.Equals(controllerSource, candidateSource);
        }

        private static object GetRequiredProperty(object target, string name)
        {
            object value = TryGetProperty(target, name);
            if (value == null) throw new InvalidOperationException("Required BveEX property was unavailable: " + name);
            return value;
        }

        private static object TryGetProperty(object target, string name)
        {
            if (target == null) return null;
            PropertyInfo property = target.GetType().GetProperty(name, All);
            return property == null ? null : property.GetValue(target, null);
        }

        private void PublishInvalid()
        {
            PublishRaw(false, BrakeSystemKind.Unknown, 0, 0, false, controlEnabled);
        }

        private void PublishInvalidNoThrow()
        {
            try { PublishInvalid(); } catch { }
        }

        private void Publish(VehicleSpec spec)
        {
            PublishRaw(true, spec.BrakeSystem, spec.PowerNotchCount, spec.BrakeNotchCount, spec.HasHoldingSpeedBrake, true);
        }

        private void PublishRaw(bool valid, BrakeSystemKind kind, int power, int brake, bool holding, bool enabled)
        {
            int odd = NextOddSequence();
            int even = odd + 1;
            view.Write(0, odd);
            view.Write(60, odd);
            view.Write(4, Magic);
            view.Write(8, SchemaVersion);
            view.Write(12, valid ? 1 : 0);
            view.Write(16, generation);
            view.Write(20, (int)kind);
            view.Write(24, power);
            view.Write(28, brake);
            view.Write(32, holding ? 1 : 0);
            view.Write(36, DateTime.UtcNow.Ticks);
            view.Write(44, System.Diagnostics.Process.GetCurrentProcess().Id);
            view.Write(48, 0L);
            view.Write(56, enabled ? 1 : 0);
            view.Write(60, even);
            view.Write(0, even);
            view.Flush();
            sequence = even;
        }


        private void UpdateControlState()
        {
            int now = Environment.TickCount;
            if (ready != null && now - lastReadyPoll < 100)
            {
                controlEnabled = ready.WaitOne(0);
                return;
            }
            lastReadyPoll = now;
            if (ready == null)
            {
                try
                {
                    int pid = Process.GetCurrentProcess().Id;
                    ready = EventWaitHandle.OpenExisting(ControlPrefix + pid + ".Ready");
                }
                catch (WaitHandleCannotBeOpenedException)
                {
                    controlEnabled = false;
                    return;
                }
            }
            try
            {
                controlEnabled = ready.WaitOne(0);
                if (!controlEnabled)
                {
                    ready.Dispose();
                    ready = null;
                }
            }
            catch
            {
                controlEnabled = false;
                if (ready != null) ready.Dispose();
                ready = null;
            }
        }

        private int NextOddSequence()
        {
            int next = sequence + 1;
            if ((next & 1) == 0) next++;
            if (next < 1) next = 1;
            return next;
        }

        private enum BrakeSystemKind { Unknown = 0, Cl = 1, Smee = 2, Ecb = 3 }
        private struct VehicleSpec
        {
            public BrakeSystemKind BrakeSystem;
            public int PowerNotchCount;
            public int BrakeNotchCount;
            public bool HasHoldingSpeedBrake;
        }
    }
}
