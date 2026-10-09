using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using Mackoy.Bvets;


namespace CorugeTo.DenGo.ControllerConverter
{
    internal static class Protocol
    {
        private const string Prefix = @"Local\CorugeTo.DenGo.VehicleSpec.Control.v1.";
        public static string Enabled(int pid) { return Prefix + pid + ".Enabled"; }
        public static string Stop(int pid) { return Prefix + pid + ".Stop"; }
    }

    public sealed class DenGoControllerConverterInputDevice : IInputDevice, IDisposable
    {
        private const string MappingName = @"Local\CorugeTo.DenGo.HandleCommand.v1";
        private const int MappingSize = 64;
        private const int Magic = 0x44474843;
        private const int SchemaVersion = 1;
        private const uint FileMapRead = 0x0004;
        private const long MaxAgeTicks = 2L * 10000000L;
        private const int AxisSHandle = 3;

        private string logPath;
        private System.Threading.EventWaitHandle enabled;
        private System.Threading.EventWaitHandle stop;
        private int axis3Minimum;
        private int axis3Maximum;
        private bool axis3Available;
        private bool disposed;
        private bool hasLastValue;
        private int lastValue;
        private int lastGeneration = -1;
        private string lastStatus;

        public event InputEventHandler LeverMoved;
        public event InputEventHandler KeyDown;
        public event InputEventHandler KeyUp;

        public void Configure(IWin32Window owner)
        {
            MessageBox.Show(
                owner,
                "DenGo Controller Converter 0.2.0.0\n\n" +
                "Vehicle-spec handshake and absolute Axis 3 handle input are enabled.\n" +
                "Reverser and key events are not controlled.",
                "DenGo Controller Converter",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
        }

        public void Load(string settingsPath)
        {
            string directory = settingsPath;
            if (String.IsNullOrEmpty(directory) || !Directory.Exists(directory))
            {
                string documentsDirectory = Environment.GetFolderPath(
                    Environment.SpecialFolder.MyDocuments);
                string bveSettingsRoot = Path.Combine(documentsDirectory, "BveTs");
                directory = Path.Combine(bveSettingsRoot, "Settings");
            }
            Directory.CreateDirectory(directory);
            logPath = Path.Combine(directory, "DenGoControllerConverter.log");
            int pid = System.Diagnostics.Process.GetCurrentProcess().Id;
            stop = new System.Threading.EventWaitHandle(false, System.Threading.EventResetMode.ManualReset, Protocol.Stop(pid));
            enabled = new System.Threading.EventWaitHandle(false, System.Threading.EventResetMode.ManualReset, Protocol.Enabled(pid));
            stop.Reset();
            enabled.Set();
            WriteLog("LOAD version=0.2.0.0 pid=" + pid);
            WriteLog("CONTRACT mapping=" + MappingName + " size=" + MappingSize);
            WriteLog("SAFETY axis=3 keyEvents=disabled reverser=untouched");
        }

        public void SetAxisRanges(int[][] ranges)
        {
            axis3Available = false;
            axis3Minimum = 0;
            axis3Maximum = 0;
            if (ranges != null && ranges.Length > AxisSHandle &&
                ranges[AxisSHandle] != null && ranges[AxisSHandle].Length > 1)
            {
                axis3Minimum = ranges[AxisSHandle][0];
                axis3Maximum = ranges[AxisSHandle][1];
                axis3Available = axis3Minimum < 0 && axis3Maximum > 0;
            }
            hasLastValue = false;
            WriteLog("AXIS3_RANGE available=" + axis3Available +
                " minimum=" + axis3Minimum + " maximum=" + axis3Maximum +
                " allRanges=" + FormatRanges(ranges));
        }

        public void Tick()
        {
            if (disposed)
            {
                return;
            }
            if (!axis3Available)
            {
                LogStatus("WAIT axis3_unavailable");
                return;
            }

            byte[] data;
            string readStatus;
            if (!TryReadMapping(out data, out readStatus))
            {
                LogStatus("WAIT mapping_" + readStatus);
                return;
            }

            Snapshot snapshot;
            string parseStatus;
            if (!TryParseSnapshot(data, out snapshot, out parseStatus))
            {
                LogStatus("WAIT snapshot_" + parseStatus);
                return;
            }

            long ageTicks = DateTime.UtcNow.Ticks - snapshot.UpdatedUtcTicks;
            if (ageTicks < 0 || ageTicks > MaxAgeTicks)
            {
                LogStatus("WAIT stale ageMs=" + (ageTicks / 10000L));
                return;
            }
            if (!snapshot.Enabled || !snapshot.Valid)
            {
                LogStatus("WAIT disabled_or_invalid enabled=" + snapshot.Enabled +
                    " valid=" + snapshot.Valid);
                return;
            }

            int requestedValue;
            string commandStatus;
            if (!TryResolveAxis3Value(snapshot, out requestedValue, out commandStatus))
            {
                LogStatus("WAIT command_" + commandStatus);
                return;
            }

            if (snapshot.Generation != lastGeneration)
            {
                WriteLog("GENERATION_CHANGE old=" + lastGeneration +
                    " new=" + snapshot.Generation);
                lastGeneration = snapshot.Generation;
            }

            int outputValue = Math.Max(axis3Minimum, Math.Min(axis3Maximum, requestedValue));
            if (hasLastValue && outputValue == lastValue)
            {
                LogStatus("READY unchanged value=" + outputValue);
                return;
            }

            InputEventHandler handler = LeverMoved;
            if (handler == null)
            {
                LogStatus("WAIT no_LeverMoved_subscriber");
                return;
            }

            handler(this, new InputEventArgs(AxisSHandle, outputValue));
            lastValue = outputValue;
            hasLastValue = true;
            lastStatus = null;
            string requestedText = snapshot.Emergency ? "EMERGENCY" : requestedValue.ToString();
            WriteLog("LEVER_MOVED axis=3 value=" + outputValue +
                " requested=" + requestedText +
                " minimum=" + axis3Minimum +
                " maximum=" + axis3Maximum +
                " sequence=" + snapshot.Sequence +
                " generation=" + snapshot.Generation +
                " brakeMode=" + snapshot.BrakeMode);
        }

        public void Dispose()
        {
            if (disposed)
            {
                return;
            }
            disposed = true;
            try { if (stop != null) stop.Set(); } catch { }
            try { if (enabled != null) enabled.Reset(); } catch { }
            if (stop != null) stop.Dispose();
            if (enabled != null) enabled.Dispose();
            stop = null;
            enabled = null;
            WriteLog("DISPOSE");
            GC.SuppressFinalize(this);
        }

        private static bool TryResolveAxis3Value(
            Snapshot snapshot,
            out int value,
            out string status)
        {
            value = 0;
            status = "invalid";
            if (snapshot.BrakeMode == 1)
            {
                int active = 0;
                if (snapshot.PowerNotch > 0) { active++; }
                if (snapshot.ServiceBrakeNotch > 0) { active++; }
                if (snapshot.Emergency) { active++; }
                if (active > 1)
                {
                    status = "electric_not_exclusive";
                    return false;
                }
                if (snapshot.Emergency)
                {
                    value = Int32.MinValue;
                }
                else if (snapshot.ServiceBrakeNotch > 0)
                {
                    value = -snapshot.ServiceBrakeNotch;
                }
                else
                {
                    value = snapshot.PowerNotch;
                }
                status = "ok";
                return true;
            }
            if (snapshot.BrakeMode == 2)
            {
                if (snapshot.ServiceBrakeNotch != 0 ||
                    snapshot.AutoBrakePosition < 0 ||
                    snapshot.AutoBrakePosition > 3 ||
                    (snapshot.AutoBrakePosition != 0 && snapshot.PowerNotch != 0) ||
                    snapshot.Emergency != (snapshot.AutoBrakePosition == 3))
                {
                    status = "automatic_air_inconsistent";
                    return false;
                }
                value = snapshot.AutoBrakePosition == 0
                    ? snapshot.PowerNotch
                    : -snapshot.AutoBrakePosition;
                status = "ok";
                return true;
            }
            status = "unsupported_brake_mode_" + snapshot.BrakeMode;
            return false;
        }

        private void LogStatus(string text)
        {
            if (String.Equals(lastStatus, text, StringComparison.Ordinal))
            {
                return;
            }
            lastStatus = text;
            WriteLog(text);
        }

        private void WriteLog(string text)
        {
            if (String.IsNullOrEmpty(logPath))
            {
                return;
            }
            try
            {
                File.AppendAllText(
                    logPath,
                    DateTime.UtcNow.ToString("o") + " " + text + Environment.NewLine,
                    new UTF8Encoding(false));
            }
            catch
            {
            }
        }

        private static string FormatRanges(int[][] ranges)
        {
            if (ranges == null)
            {
                return "<null>";
            }
            StringBuilder builder = new StringBuilder();
            for (int axis = 0; axis < ranges.Length; axis++)
            {
                if (axis > 0) { builder.Append(";"); }
                builder.Append(axis).Append(":");
                if (ranges[axis] == null)
                {
                    builder.Append("<null>");
                    continue;
                }
                builder.Append("[");
                for (int index = 0; index < ranges[axis].Length; index++)
                {
                    if (index > 0) { builder.Append(","); }
                    builder.Append(ranges[axis][index]);
                }
                builder.Append("]");
            }
            return builder.ToString();
        }

        private static bool TryReadMapping(out byte[] data, out string status)
        {
            data = null;
            status = "unknown";
            IntPtr mapping = OpenFileMapping(FileMapRead, false, MappingName);
            if (mapping == IntPtr.Zero)
            {
                status = "not_found error=" + Marshal.GetLastWin32Error();
                return false;
            }
            try
            {
                IntPtr view = MapViewOfFile(mapping, FileMapRead, 0, 0,
                    new UIntPtr((uint)MappingSize));
                if (view == IntPtr.Zero)
                {
                    status = "map_failed error=" + Marshal.GetLastWin32Error();
                    return false;
                }
                try
                {
                    data = new byte[MappingSize];
                    Marshal.Copy(view, data, 0, MappingSize);
                    status = "ok";
                    return true;
                }
                finally
                {
                    UnmapViewOfFile(view);
                }
            }
            finally
            {
                CloseHandle(mapping);
            }
        }

        private static bool TryParseSnapshot(byte[] data, out Snapshot snapshot, out string status)
        {
            snapshot = new Snapshot();
            status = "invalid";
            if (data == null || data.Length < MappingSize)
            {
                status = "short";
                return false;
            }
            int sequenceStart = BitConverter.ToInt32(data, 0);
            int magic = BitConverter.ToInt32(data, 4);
            int schema = BitConverter.ToInt32(data, 8);
            int sequenceEnd = BitConverter.ToInt32(data, 60);
            if (sequenceStart != sequenceEnd || (sequenceStart & 1) != 0)
            {
                status = "torn";
                return false;
            }
            if (magic != Magic || schema != SchemaVersion)
            {
                status = "contract_mismatch";
                return false;
            }
            snapshot.Sequence = sequenceStart;
            snapshot.PublisherProcessId = BitConverter.ToInt32(data, 12);
            snapshot.Generation = BitConverter.ToInt32(data, 16);
            snapshot.Enabled = BitConverter.ToInt32(data, 20) != 0;
            snapshot.Valid = BitConverter.ToInt32(data, 24) != 0;
            snapshot.BrakeMode = BitConverter.ToInt32(data, 28);
            snapshot.PowerNotch = BitConverter.ToInt32(data, 32);
            snapshot.ServiceBrakeNotch = BitConverter.ToInt32(data, 36);
            snapshot.Emergency = BitConverter.ToInt32(data, 40) != 0;
            snapshot.AutoBrakePosition = BitConverter.ToInt32(data, 44);
            snapshot.UpdatedUtcTicks = BitConverter.ToInt64(data, 48);
            status = "ok";
            return true;
        }

        private struct Snapshot
        {
            internal int Sequence;
            internal int PublisherProcessId;
            internal int Generation;
            internal bool Enabled;
            internal bool Valid;
            internal int BrakeMode;
            internal int PowerNotch;
            internal int ServiceBrakeNotch;
            internal bool Emergency;
            internal int AutoBrakePosition;
            internal long UpdatedUtcTicks;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenFileMapping(uint desiredAccess, bool inheritHandle, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr MapViewOfFile(
            IntPtr fileMappingObject,
            uint desiredAccess,
            uint fileOffsetHigh,
            uint fileOffsetLow,
            UIntPtr numberOfBytesToMap);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnmapViewOfFile(IntPtr baseAddress);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);
    }
}
