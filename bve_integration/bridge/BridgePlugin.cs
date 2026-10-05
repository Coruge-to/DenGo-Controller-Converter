using System;
using System.Diagnostics;
using System.Threading;
using BveEx.PluginHost;
using BveEx.PluginHost.Plugins;
using BveEx.PluginHost.Plugins.Extensions;

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

    [Plugin(PluginType.Extension)]
    public sealed class DenGoVehicleSpecBridge : AssemblyPluginBase, IExtension
    {
        private readonly int pid = Process.GetCurrentProcess().Id;
        private readonly ManualResetEvent shutdown = new ManualResetEvent(false);
        private readonly Thread worker;
        private EventWaitHandle available;
        private EventWaitHandle enabled;
        private EventWaitHandle stop;
        private EventWaitHandle ready;
        private bool disposed;

        public DenGoVehicleSpecBridge(PluginBuilder builder) : base(builder)
        {
            available = new EventWaitHandle(false, EventResetMode.ManualReset, Protocol.BridgeAvailable(pid));
            available.Set();
            worker = new Thread(WorkerLoop);
            worker.IsBackground = true;
            worker.Name = "DenGo VehicleSpec handshake bridge";
            worker.Start();
        }

        public override void Tick(TimeSpan elapsed)
        {
            // Control handshaking is intentionally independent of BVE simulation time.
        }

        private void WorkerLoop()
        {
            while (!shutdown.WaitOne(0))
            {
                try
                {
                    if (ready == null)
                    {
                        TryConnect();
                    }
                    else if (!StillEnabled())
                    {
                        ReleaseConnection();
                    }
                }
                catch
                {
                    ReleaseConnection();
                }
                shutdown.WaitOne(20);
            }
            ReleaseConnection();
        }

        private void TryConnect()
        {
            EventWaitHandle candidateEnabled = null;
            EventWaitHandle candidateStop = null;
            try
            {
                candidateEnabled = EventWaitHandle.OpenExisting(Protocol.Enabled(pid));
                candidateStop = EventWaitHandle.OpenExisting(Protocol.Stop(pid));
                if (!candidateEnabled.WaitOne(0) || candidateStop.WaitOne(0)) return;

                enabled = candidateEnabled;
                candidateEnabled = null;
                stop = candidateStop;
                candidateStop = null;
                ready = new EventWaitHandle(false, EventResetMode.ManualReset, Protocol.Ready(pid));
                ready.Set();
            }
            catch (WaitHandleCannotBeOpenedException)
            {
            }
            finally
            {
                if (candidateEnabled != null) candidateEnabled.Dispose();
                if (candidateStop != null) candidateStop.Dispose();
            }
        }

        private bool StillEnabled()
        {
            try
            {
                return enabled != null && stop != null && enabled.WaitOne(0) && !stop.WaitOne(0);
            }
            catch
            {
                return false;
            }
        }

        private void ReleaseConnection()
        {
            try { if (ready != null) ready.Reset(); } catch { }
            if (ready != null) ready.Dispose();
            if (stop != null) stop.Dispose();
            if (enabled != null) enabled.Dispose();
            ready = null;
            stop = null;
            enabled = null;
        }

        public override void Dispose()
        {
            if (disposed) return;
            disposed = true;
            shutdown.Set();
            try { worker.Join(1000); } catch { }
            ReleaseConnection();
            try { if (available != null) available.Reset(); } catch { }
            if (available != null) available.Dispose();
            available = null;
            shutdown.Dispose();
        }
    }
}
