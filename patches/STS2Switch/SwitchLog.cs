// SwitchLog.cs -- logging from patched game code into the wrapper's log.
//
// The Android launcher used PatchHelper.Log, which went to Godot's print. That
// works here too, but the wrapper writes its own log to
// <data_root>/sts2_debug.log, and interleaving the two is what makes a boot
// failure readable -- a managed error next to the native call that caused it.
//
// P/Invokes into the NRO's own exports. "__Internal" is the NativeAOT
// convention for "already in this process image": the wrapper loads the AOT
// payload into the same address space, so sts2_managed_log resolves directly.
//
// MIT license; see LICENSE.

using System.Runtime.InteropServices;

namespace STS2Switch;

public static class SwitchLog
{
    [DllImport("__Internal", EntryPoint = "sts2_managed_log", CharSet = CharSet.Ansi)]
    private static extern void NativeLog(int level, string message);

    private const int LEVEL_INFO = 0;
    private const int LEVEL_ERROR = 1;

    public static void Info(string message) => Write(LEVEL_INFO, message);
    public static void Error(string message) => Write(LEVEL_ERROR, message);

    // Try every channel, in order of proven reliability, and stop at the first
    // that works. Log lines are rare enough that the cost is irrelevant, and
    // the alternative -- latching one channel -- is what hid the ModelDb
    // counters in run 15.
    //
    //   GD.Print       PROVEN. Every C# stack trace in every log so far arrived
    //                  this way, as a [godot] line. Unavailable until GodotSharp
    //                  is initialised, so it cannot be the only channel.
    //   Console.Error  wrapper mirrors fd 1/2 as [fd2] (nativeaot_shim.c).
    //                  Produced nothing across runs 13 to 15 despite the
    //                  mirroring being present, so it is not trusted first.
    //   NativeLog      DllImport("__Internal"), which resolves only if the
    //                  payload's own exports are reachable.
    //
    // Anything that throws is skipped rather than swallowed: the previous
    // version caught silently, so "the patch did not run" and "the patch ran
    // and could not say so" looked identical. They are very different problems.
    // Patch-set fingerprint, printed once by the first log line.
    //
    // Three rounds have been spent on logs from a payload that predated the
    // fix being tested -- each time diagnosed by noticing an expected message
    // was absent, which is slow and ambiguous (absent because it did not run,
    // or because it is not in this build?).
    //
    // This is a hash of ModelDbPatches.cs + PlatformPatches.cs at weave time,
    // so a glance at the log says which patch set is actually on the card.
    public const string PatchSetId = "3ed8a25c";

    private static bool _announced;

    private static void Write(int level, string message)
    {
        if (!_announced)
        {
            _announced = true;
            Write(LEVEL_INFO, "patch set " + PatchSetId);

            // Deliberate side effect, and the earliest reliable hook there is.
            // The culture must be set before LocManager's constructor, and the
            // first log line beats every patched method. Idempotent, so the
            // other call sites cost nothing.
            SwitchCulture.Ensure();

            // Before any texture load. The overlay only takes effect for
            // resources loaded after the pack is mounted, so late is the same
            // as never.
            AstcOverlay.Ensure();
        }

        string tagged = (level == LEVEL_ERROR ? "[sts2 ERROR] " : "[sts2] ") + message;

#if HAVE_GODOTSHARP
        try
        {
            if (level == LEVEL_ERROR) Godot.GD.PushError(tagged);
            else                      Godot.GD.Print(tagged);
            return;
        }
        catch { /* GodotSharp not up yet; fall through */ }
#endif

        try { System.Console.Error.WriteLine(tagged); return; }
        catch { }

        try { NativeLog(level, message); }
        catch { }
    }
}
