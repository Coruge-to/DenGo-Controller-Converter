using System;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Mackoy.Bvets;
using Microsoft.Win32;


namespace CorugeTo.DenGo.ControllerConverter
{
    internal static class Protocol
    {
        private const string Prefix = @"Local\CorugeTo.DenGo.VehicleSpec.Control.v1.";
        public static string Enabled(int pid) { return Prefix + pid + ".Enabled"; }
        public static string Stop(int pid) { return Prefix + pid + ".Stop"; }
        public static string BridgeAvailable(int pid) { return Prefix + pid + ".BridgeAvailable"; }
    }

    public sealed class DenGoControllerConverterInputDevice : IInputDevice, IDisposable
    {
        private const string MappingName = @"Local\CorugeTo.DenGo.HandleCommand.v1";
        private const int MappingSize = 64;
        private const int Magic = 0x44474843;
        private const int SchemaVersion = 2;
        private const uint FileMapRead = 0x0004;
        private const uint Synchronize = 0x00100000;
        private const long MaxAgeTicks = 2L * 10000000L;
        private const int AxisSHandle = 3;
        private const int FunctionKeyAxis = -1;
        private const int Horn1Key = 0;
        private const int Horn2Key = 1;
        private const int StartButtonMask = 0x01;
        private const int SelectButtonMask = 0x02;
        private const int SupportedButtonMask = StartButtonMask | SelectButtonMask;
        private const int BridgeLostNoticeMs = 500;
        private const int MonitorIntervalMs = 50;
        private const uint MbOk = 0x00000000;
        private const uint MbIconInformation = 0x00000040;
        private const uint MbSetForeground = 0x00010000;
        private const uint MbTopMost = 0x00040000;
        private const string ProductDisplayName = "DenGo Controller Converter";
        private const string AppMutexName = @"Local\CorugeTo.DenGo.ControllerConverter.App.v1";
        private const string InstallRegistryKey = @"Software\Coruge-to\DenGo Controller Converter";
        private const string LauncherArgumentsValue = "LauncherArguments";
        private const string AppMissingNoticeText =
            "DenGo Controller Converter本体が見つかりません。\r\n" +
            "DenGo Controller Converterを再インストールしてください。";
        private const string BveExNoticeText =
            "DenGo Controller ConverterにはBveEXが必要です。\r\n" +
            "設定 → 入力デバイス でBveEXを有効にし、BVEを再起動してください。";

        private string logPath;
        private EventWaitHandle enabled;
        private EventWaitHandle stop;
        private EventWaitHandle monitorStop;
        private Thread bridgeMonitorThread;
        private int noticeStarted;
        private int appNoticeStarted;
        private int appStartAttempted;
        private bool bridgeSeen;
        private long bridgeMissingSinceQpc;
        private int bveProcessId;
        private int axis3Minimum;
        private int axis3Maximum;
        private bool axis3Available;
        private bool disposed;
        private bool hasLastValue;
        private int lastValue;
        private int lastGeneration = -1;
        private int pressedButtonMask;
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
                "Reverser is not controlled. START and SELECT drive BVE horn key events.",
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
            int pid = Process.GetCurrentProcess().Id;
            bveProcessId = pid;
            stop = new EventWaitHandle(false, EventResetMode.ManualReset, Protocol.Stop(pid));
            enabled = new EventWaitHandle(false, EventResetMode.ManualReset, Protocol.Enabled(pid));
            monitorStop = new EventWaitHandle(false, EventResetMode.ManualReset);
            stop.Reset();
            enabled.Set();
            bridgeMonitorThread = new Thread(BridgeMonitorLoop);
            bridgeMonitorThread.IsBackground = true;
            bridgeMonitorThread.Name = "DenGo BveEX dependency monitor";
            bridgeMonitorThread.Start();
            WriteLog("LOAD version=0.2.0.0 pid=" + pid);
            WriteLog("CONTRACT mapping=" + MappingName + " size=" + MappingSize);
            WriteLog("SAFETY axis=3 keyEvents=bve-horns-only reverser=untouched");
            StartConverterIfNeeded();
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
            if (axis3Available && !ProbeBridgeAvailable())
            {
                StartBveExNoticeIfStillNeeded("scenario-ready");
            }
        }

        public void Tick()
        {
            if (disposed)
            {
                return;
            }
            if (!axis3Available)
            {
                ReleasePressedButtons();
                LogStatus("WAIT axis3_unavailable");
                return;
            }

            byte[] data;
            string readStatus;
            if (!TryReadMapping(out data, out readStatus))
            {
                ReleasePressedButtons();
                LogStatus("WAIT mapping_" + readStatus);
                return;
            }

            Snapshot snapshot;
            string parseStatus;
            if (!TryParseSnapshot(data, out snapshot, out parseStatus))
            {
                ReleasePressedButtons();
                LogStatus("WAIT snapshot_" + parseStatus);
                return;
            }

            long ageTicks = DateTime.UtcNow.Ticks - snapshot.UpdatedUtcTicks;
            if (ageTicks < 0 || ageTicks > MaxAgeTicks)
            {
                ReleasePressedButtons();
                LogStatus("WAIT stale");
                return;
            }
            if (!snapshot.Enabled || !snapshot.Valid)
            {
                ReleasePressedButtons();
                LogStatus("WAIT disabled_or_invalid enabled=" + snapshot.Enabled +
                    " valid=" + snapshot.Valid);
                return;
            }

            int requestedValue;
            string commandStatus;
            if (!TryResolveAxis3Value(snapshot, out requestedValue, out commandStatus))
            {
                ReleasePressedButtons();
                LogStatus("WAIT command_" + commandStatus);
                return;
            }

            if (snapshot.Generation != lastGeneration)
            {
                ReleasePressedButtons();
                WriteLog("GENERATION_CHANGE old=" + lastGeneration +
                    " new=" + snapshot.Generation);
                lastGeneration = snapshot.Generation;
            }

            ApplyButtonMask(snapshot.ButtonMask, snapshot.Sequence, snapshot.Generation);

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
            ReleasePressedButtons();
            disposed = true;
            try { if (monitorStop != null) monitorStop.Set(); } catch { }
            try { if (stop != null) stop.Set(); } catch { }
            try { if (enabled != null) enabled.Reset(); } catch { }
            Thread monitor = bridgeMonitorThread;
            if (monitor != null && monitor != Thread.CurrentThread)
            {
                try { monitor.Join(1000); } catch { }
            }
            bridgeMonitorThread = null;
            if (monitorStop != null) monitorStop.Dispose();
            if (stop != null) stop.Dispose();
            if (enabled != null) enabled.Dispose();
            monitorStop = null;
            stop = null;
            enabled = null;
            WriteLog("DISPOSE");
            GC.SuppressFinalize(this);
        }


        private void ApplyButtonMask(int requestedMask, int sequence, int generation)
        {
            if ((pressedButtonMask ^ requestedMask) == 0) return;
            ApplyButtonTransition(StartButtonMask, Horn2Key, requestedMask, sequence, generation, "START");
            ApplyButtonTransition(SelectButtonMask, Horn1Key, requestedMask, sequence, generation, "SELECT");
        }

        private void ApplyButtonTransition(int mask, int keyIndex, int requestedMask,
            int sequence, int generation, string name)
        {
            bool wasPressed = (pressedButtonMask & mask) != 0;
            bool isPressed = (requestedMask & mask) != 0;
            if (wasPressed == isPressed) return;

            InputEventHandler handler = isPressed ? KeyDown : KeyUp;
            if (handler == null)
            {
                LogStatus("WAIT no_" + (isPressed ? "KeyDown" : "KeyUp") + "_subscriber");
                if (!isPressed) pressedButtonMask &= ~mask;
                return;
            }

            handler(this, new InputEventArgs(FunctionKeyAxis, keyIndex));
            if (isPressed) pressedButtonMask |= mask;
            else pressedButtonMask &= ~mask;
            lastStatus = null;
            WriteLog("KEY_" + (isPressed ? "DOWN" : "UP") +
                " name=" + name + " axis=" + FunctionKeyAxis + " value=" + keyIndex +
                " sequence=" + sequence + " generation=" + generation);
        }

        private void ReleasePressedButtons()
        {
            int buttonsToRelease = pressedButtonMask;
            if (buttonsToRelease == 0) return;

            InputEventHandler handler = KeyUp;
            if (handler != null)
            {
                if ((buttonsToRelease & StartButtonMask) != 0)
                {
                    handler(this, new InputEventArgs(FunctionKeyAxis, Horn2Key));
                    WriteLog("KEY_UP name=START reason=safety-release");
                }
                if ((buttonsToRelease & SelectButtonMask) != 0)
                {
                    handler(this, new InputEventArgs(FunctionKeyAxis, Horn1Key));
                    WriteLog("KEY_UP name=SELECT reason=safety-release");
                }
            }
            pressedButtonMask = 0;
        }

        private void StartConverterIfNeeded()
        {
            if (Interlocked.CompareExchange(ref appStartAttempted, 1, 0) != 0)
            {
                return;
            }
            IntPtr mutex = OpenMutex(Synchronize, false, AppMutexName);
            if (mutex != IntPtr.Zero)
            {
                CloseHandle(mutex);
                WriteLog("APP_AUTOSTART skipped reason=already-running");
                return;
            }
            string launcherPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "Programs",
                ProductDisplayName,
                "DenGoControllerConverter.exe");
            string launcherArguments = null;
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(InstallRegistryKey))
                {
                    if (key != null)
                    {
                        launcherArguments = key.GetValue(LauncherArgumentsValue) as string;
                    }
                }
            }
            catch (Exception ex)
            {
                WriteLog("APP_AUTOSTART registry-error=" + ex.GetType().Name);
            }
            if (!File.Exists(launcherPath))
            {
                WriteLog("APP_AUTOSTART failed reason=installed-launcher-not-found path=" + launcherPath);
                StartAppMissingNoticeIfNeeded();
                return;
            }
            WriteLog("APP_AUTOSTART launcher=" + launcherPath);
            try
            {
                string arguments = String.IsNullOrWhiteSpace(launcherArguments)
                    ? String.Empty
                    : launcherArguments.Trim() + " ";
                arguments += "--started-by bve --bve-pid " + bveProcessId;
                ProcessStartInfo info = new ProcessStartInfo();
                info.FileName = launcherPath;
                info.Arguments = arguments;
                info.WorkingDirectory = Path.GetDirectoryName(launcherPath);
                info.UseShellExecute = false;
                Process process = Process.Start(info);
                WriteLog("APP_AUTOSTART started pid=" + (process == null ? 0 : process.Id));
                if (process != null) process.Dispose();
            }
            catch (Exception ex)
            {
                WriteLog("APP_AUTOSTART failed reason=" + ex.GetType().Name + " " + ex.Message);
                StartAppMissingNoticeIfNeeded();
            }
        }
        private void StartAppMissingNoticeIfNeeded()
        {
            if (Interlocked.CompareExchange(ref appNoticeStarted, 1, 0) != 0) return;
            Thread thread = new Thread(delegate()
            {
                MessageBoxW(IntPtr.Zero, AppMissingNoticeText, ProductDisplayName,
                    MbOk | MbIconInformation | MbSetForeground | MbTopMost);
            });
            thread.IsBackground = true;
            thread.Name = "DenGo application missing notice";
            thread.Start();
        }
        private void BridgeMonitorLoop()
        {
            try
            {
                while (!disposed)
                {
                    bool bridgePresent = ProbeBridgeAvailable();
                    long now = Stopwatch.GetTimestamp();

                    if (bridgePresent)
                    {
                        bridgeSeen = true;
                        bridgeMissingSinceQpc = 0;
                    }
                    else if (bridgeSeen)
                    {
                        {
                            if (bridgeMissingSinceQpc == 0)
                            {
                                bridgeMissingSinceQpc = now;
                            }
                            double missingMs = (now - bridgeMissingSinceQpc) * 1000.0 / Stopwatch.Frequency;
                            if (missingMs >= BridgeLostNoticeMs)
                            {
                                StartBveExNoticeIfStillNeeded("connection-lost");
                            }
                        }
                    }

                    EventWaitHandle quit = monitorStop;
                    if (quit == null || quit.WaitOne(MonitorIntervalMs))
                    {
                        break;
                    }
                }
            }
            catch (Exception ex)
            {
                WriteLog("BVEEX_MONITOR_ERROR " + ex.GetType().Name + " " + ex.Message);
            }
        }

        private bool ProbeBridgeAvailable()
        {
            EventWaitHandle bridge = null;
            try
            {
                if (!EventWaitHandle.TryOpenExisting(
                    Protocol.BridgeAvailable(bveProcessId),
                    System.Security.AccessControl.EventWaitHandleRights.Synchronize,
                    out bridge))
                {
                    return false;
                }
                return bridge.WaitOne(0);
            }
            catch
            {
                return false;
            }
            finally
            {
                if (bridge != null) bridge.Dispose();
            }
        }

        private void StartBveExNoticeIfStillNeeded(string trigger)
        {
            if (Interlocked.CompareExchange(ref noticeStarted, 1, 0) != 0)
            {
                return;
            }

            Thread noticeThread = new Thread(delegate()
            {
                try
                {
                    if (disposed || ProbeBridgeAvailable())
                    {
                        WriteLog("BVEEX_NOTICE_SUPPRESSED trigger=" + trigger);
                        return;
                    }

                    WriteLog("BVEEX_NOTICE_SHOWN trigger=" + trigger);
                    MessageBoxW(
                        IntPtr.Zero,
                        BveExNoticeText,
                        ProductDisplayName,
                        MbOk | MbIconInformation | MbSetForeground | MbTopMost);
                }
                catch (Exception ex)
                {
                    WriteLog("BVEEX_NOTICE_ERROR " + ex.GetType().Name + " " + ex.Message);
                }
            });
            noticeThread.IsBackground = true;
            noticeThread.Name = "DenGo BveEX dependency notice";
            noticeThread.Start();
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
            snapshot.ButtonMask = BitConverter.ToInt32(data, 56);
            if (snapshot.ButtonMask < 0 || (snapshot.ButtonMask & ~SupportedButtonMask) != 0)
            {
                status = "unsupported_button_mask";
                return false;
            }
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
            internal int ButtonMask;
        }

        [DllImport("user32.dll", EntryPoint = "MessageBoxW", CharSet = CharSet.Unicode)]
        private static extern int MessageBoxW(IntPtr hWnd, string text, string caption, uint type);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr OpenMutex(uint desiredAccess, bool inheritHandle, string name);
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
