namespace NzbDrone.Common.EnvironmentInfo
{
    // Upstream RuntimeInfo reads the process, the OS and Windows service state
    // and pulls in Microsoft.Extensions.Hosting. The vendored HTTP code only
    // reads RuntimeInfo.IsProduction, so that is all this exposes. Production
    // behavior is what a released Prowlarr does (auto redirect on).
    public static class RuntimeInfo
    {
        public static bool IsProduction => true;
        public static bool IsTesting => false;
        public static bool IsDevelopment => false;
    }
}
