#if WASM_BUILD
using CardigannWorld.wit.Imports.mydia.cardigann.v1_0_0;
using NLog;
using NLog.Targets;

namespace Mydia.CardigannGuest.Shim
{
    // Forwards NLog events to the host's log import (0 trace .. 4 error).
    public sealed class HostLogTarget : TargetWithLayout
    {
        protected override void Write(LogEventInfo logEvent)
        {
            var level = (byte)System.Math.Min(logEvent.Level.Ordinal, 4);
            IHostImports.Log(level, RenderLogEvent(Layout, logEvent));
        }
    }
}
#endif
