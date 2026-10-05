using System;
using System.Diagnostics;
using System.Threading;
using System.Windows.Forms;
using Mackoy.Bvets;

namespace CorugeTo.DenGo.VehicleSpec.Handshake
{
    internal static class Protocol
    {
        private const string Prefix = @"Local\CorugeTo.DenGo.VehicleSpec.Control.v1.";
        public static string Enabled(int pid) { return Prefix + pid + ".Enabled"; }
        public static string Stop(int pid) { return Prefix + pid + ".Stop"; }
        public static string BridgeAvailable(int pid) { return Prefix + pid + ".BridgeAvailable"; }
        public static string Ready(int pid) { return Prefix + pid + ".Ready"; }
    }

    public sealed class DenGoVehicleSpecCaller : IInputDevice, IDisposable
    {
        private EventWaitHandle enabled;
        private EventWaitHandle stop;
        private bool disposed;

        public event InputEventHandler LeverMoved { add { } remove { } }
        public event InputEventHandler KeyDown { add { } remove { } }
        public event InputEventHandler KeyUp { add { } remove { } }

        public void Load(string path)
        {
            int pid = Process.GetCurrentProcess().Id;
            stop = new EventWaitHandle(false, EventResetMode.ManualReset, Protocol.Stop(pid));
            enabled = new EventWaitHandle(false, EventResetMode.ManualReset, Protocol.Enabled(pid));
            stop.Reset();
            enabled.Set();
        }

        public void Tick() { }
        public void SetAxisRanges(int[][] ranges) { }
        public void Configure(IWin32Window owner) { }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            try { if (stop != null) stop.Set(); } catch { }
            try { if (enabled != null) enabled.Reset(); } catch { }
            if (stop != null) stop.Dispose();
            if (enabled != null) enabled.Dispose();
        }
    }
}
