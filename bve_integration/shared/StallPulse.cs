// DenGo VehicleSpec plugins: keeps the shared-memory snapshot fresh while the extension Tick is stalled (Pause, menus).
//
// While BVE is paused the extension Tick stops, the published snapshot goes stale and the Caller/Python stop trusting it. This helper watches the
// time since the last Tick and, only while no Tick has arrived for StallMs, posts a read-only refresh to the BVE UI thread every PeriodMs
// (SynchronizationContext.Post, so the refresh runs on the same thread as Tick and never overlaps it).
using System;
using System.Diagnostics;
using System.Threading;

namespace DenGoVehicleSpecShared
{
    internal sealed class StallPulse
    {
        internal const int PeriodMs = 16;
        internal const int StallMs = 80;

        private readonly Action refresh;
        private long lastTick = Stopwatch.GetTimestamp();
        private int pending;
        private volatile bool stopped;
        private Thread thread;
        private SynchronizationContext context;

        internal StallPulse(Action refresh)
        {
            this.refresh = refresh;
        }

        // Call from the UI thread at the start of every Tick.
        internal void NoteTick()
        {
            lastTick = Stopwatch.GetTimestamp();
        }

        // Call once from the UI thread (the first Tick); captures the UI SynchronizationContext. No-op if there is none.
        internal void Start()
        {
            if (thread != null || stopped) return;
            context = SynchronizationContext.Current;
            if (context == null) { thread = new Thread(delegate () { }); return; }
            thread = new Thread(Loop);
            thread.IsBackground = true;
            thread.Name = "DenGo VehicleSpec stall pulse";
            thread.Start();
        }

        internal void Stop()
        {
            stopped = true;
        }

        private static double MsSince(long timestamp)
        {
            return (Stopwatch.GetTimestamp() - timestamp) * 1000.0 / Stopwatch.Frequency;
        }

        private void Loop()
        {
            while (!stopped)
            {
                Thread.Sleep(PeriodMs);
                try
                {
                    if (MsSince(lastTick) >= StallMs && Interlocked.CompareExchange(ref pending, 1, 0) == 0)
                    {
                        try { context.Post(Run, null); }
                        catch { Interlocked.Exchange(ref pending, 0); }
                    }
                }
                catch { }
            }
        }

        // Runs on the UI thread.
        private void Run(object state)
        {
            Interlocked.Exchange(ref pending, 0);
            try
            {
                if (stopped || MsSince(lastTick) < StallMs) return;
                refresh();
            }
            catch { }
        }
    }
}
