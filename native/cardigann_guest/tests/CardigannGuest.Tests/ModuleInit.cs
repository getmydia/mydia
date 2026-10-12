using System.Runtime.CompilerServices;
using Mydia.CardigannGuest.Shim;

namespace Mydia.CardigannGuest.Tests
{
    internal static class TestSetup
    {
        // Upstream waits seconds between retries of a server error; tests do not.
        [ModuleInitializer]
        internal static void NoRetryWaits() => BlockingTimeProvider.Sleep = _ => { };
    }
}
