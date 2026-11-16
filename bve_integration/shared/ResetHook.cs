// DenGo VehicleSpec plugins: counts BVE-internal vehicle resets (station jump / scenario reload / F5) so that the Caller can re-send the
// physical controller position once after BVE itself changed the handle.
//
// How it works: a Harmony Postfix on the BVE-internal Vehicle.Initialize(BrakePosition) increments a monotonic counter and hands it to the
// plugin, which publishes it in the reserved 8 bytes at offset 48 of the VehicleSpec mapping. Nothing else is changed: the Postfix takes no
// arguments, returns nothing and swallows every exception.
//
// Isolation: every reference to 0Harmony lives in the nested HarmonyBinding class and is reached only through NoInlining entry points inside a
// try block. If 0Harmony is missing or incompatible, or the BVE-internal method cannot be found, Install() returns a reason string, the counter
// simply stays at 0, and the product behaves exactly as before (the first send after SetAxisRanges still happens).
using System;
using System.IO;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text;
using System.Threading;

namespace DenGoVehicleSpecShared
{
    internal static class ResetHook
    {
        private const string HarmonyId = "CorugeTo.DenGo.VehicleSpec.ResetHook.v1";
        private const string WrapperTypeName = "BveTypes.ClassWrappers.Vehicle";
        private const string BrakePositionTypeName = "BveTypes.ClassWrappers.BrakePosition";
        private const string MethodName = "Initialize";

        private static long resetCount;
        private static Action<long> onReset;

        internal static long Count { get { return Interlocked.Read(ref resetCount); } }

        // Returns "ok" or a short failure reason. Never throws.
        internal static string Install(object bveHacker, Action<long> publishCount)
        {
            try
            {
                onReset = publishCount;
                MethodInfo original = FindOriginal(bveHacker);
                if (original == null) return Log("disabled reason=no_source_method");
                string status = HarmonyBinding.Patch(HarmonyId, original, typeof(ResetHook).GetMethod("Postfix", BindingFlags.Static | BindingFlags.NonPublic));
                return Log(status);
            }
            catch (Exception ex)
            {
                return Log("disabled reason=" + ex.GetType().Name);
            }
        }

        internal static void Uninstall()
        {
            try { HarmonyBinding.Unpatch(HarmonyId); } catch { }
            onReset = null;
        }

        // Harmony Postfix. Runs on the BVE main thread at the end of Vehicle.Initialize(BrakePosition).
        private static void Postfix()
        {
            try
            {
                long count = Interlocked.Increment(ref resetCount);
                Action<long> publish = onReset;
                if (publish != null) publish(count);
            }
            catch { }
        }

        private static MethodInfo FindOriginal(object bveHacker)
        {
            object typeSet = GetProperty(bveHacker, "BveTypes");
            if (typeSet == null) return null;
            Assembly asm = typeSet.GetType().Assembly;
            Type wrapper = asm.GetType(WrapperTypeName);
            Type brakePosition = asm.GetType(BrakePositionTypeName);
            if (wrapper == null || brakePosition == null) return null;
            object classInfo = Invoke(typeSet, "GetClassInfoOf", new Type[] { typeof(Type) }, wrapper);
            if (classInfo == null) return null;
            object member = Invoke(classInfo, "GetSourceMethodOf", new Type[] { typeof(string), typeof(Type[]) }, MethodName, new Type[] { brakePosition });
            return GetProperty(member, "Source") as MethodInfo;
        }

        private static object GetProperty(object target, string name)
        {
            if (target == null) return null;
            PropertyInfo p = target.GetType().GetProperty(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
            return p == null ? null : p.GetValue(target, null);
        }

        private static object Invoke(object target, string method, Type[] signature, params object[] args)
        {
            MethodInfo m = target.GetType().GetMethod(method, signature);
            if (m == null) throw new MissingMethodException(method);
            return m.Invoke(target, args);
        }

        private static string Log(string text)
        {
            try
            {
                string docs = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
                string path = Path.Combine(Path.Combine(Path.Combine(docs, "BveTs"), "Settings"), "DenGoControllerConverter.log");
                File.AppendAllText(path, DateTime.UtcNow.ToString("o") + " RESET_HOOK " + text + Environment.NewLine, new UTF8Encoding(false));
            }
            catch { }
            return text;
        }

        // All references to 0Harmony are confined to this class (reached only through the NoInlining methods below, inside try blocks).
        private static class HarmonyBinding
        {
            [MethodImpl(MethodImplOptions.NoInlining)]
            internal static string Patch(string id, MethodInfo original, MethodInfo postfix)
            {
                HarmonyLib.Harmony harmony = new HarmonyLib.Harmony(id);
                harmony.Patch(original, null, new HarmonyLib.HarmonyMethod(postfix));
                return "ok harmony=" + typeof(HarmonyLib.Harmony).Assembly.GetName().Version;
            }

            [MethodImpl(MethodImplOptions.NoInlining)]
            internal static void Unpatch(string id)
            {
                new HarmonyLib.Harmony(id).UnpatchAll(id);
            }
        }
    }
}
