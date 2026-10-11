using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using NzbDrone.Common.Http.Proxy;
using NzbDrone.Common.Messaging;
using NzbDrone.Common.TPL;
using NzbDrone.Core.Configuration;
using NzbDrone.Core.Messaging.Events;
using NzbDrone.Core.Security;

namespace Mydia.CardigannGuest.Shim
{
    public sealed class NullEventAggregator : IEventAggregator
    {
        public void PublishEvent<TEvent>(TEvent @event)
            where TEvent : class, IEvent
        {
        }
    }

    // The host rate-limits requests, so the guest never sleeps.
    public sealed class NoRateLimitService : IRateLimitService
    {
        public void WaitAndPulse(string key, TimeSpan interval)
        {
        }

        public Task WaitAndPulseAsync(string key, TimeSpan interval) => Task.CompletedTask;
    }

    // Replaces the database-backed ConfigService. Values are Prowlarr's defaults.
    public sealed class CallConfigService : IConfigService
    {
        public void SaveConfigDictionary(Dictionary<string, object> configValues)
        {
        }

        public bool IsDefined(string key) => false;

        public int HistoryCleanupDays { get; set; } = 30;
        public int FirstDayOfWeek { get; set; }
        public string CalendarWeekColumnHeader { get; set; } = "ddd M/D";
        public string ShortDateFormat { get; set; } = "MMM D YYYY";
        public string LongDateFormat { get; set; } = "dddd, MMMM D YYYY";
        public string TimeFormat { get; set; } = "h(:mm)a";
        public bool ShowRelativeDates { get; set; } = true;
        public bool EnableColorImpairedMode { get; set; }
        public string UILanguage { get; set; } = "en";

        public string PlexClientIdentifier => string.Empty;

        public string RijndaelPassphrase => string.Empty;
        public string HmacPassphrase => string.Empty;
        public string RijndaelSalt => string.Empty;
        public string HmacSalt => string.Empty;

        public string DownloadProtectionKey => string.Empty;

        public bool ProxyEnabled => false;
        public ProxyType ProxyType => ProxyType.Http;
        public string ProxyHostname => string.Empty;
        public int ProxyPort => 8080;
        public string ProxyUsername => string.Empty;
        public string ProxyPassword => string.Empty;
        public string ProxyBypassFilter => string.Empty;
        public bool ProxyBypassLocalAddresses => true;

        public string BackupFolder => string.Empty;
        public int BackupInterval => 7;
        public int BackupRetention => 28;

        public bool LogIndexerResponse { get; set; }

        public CertificateValidationType CertificateValidation => CertificateValidationType.Enabled;
        public string ApplicationUrl => string.Empty;
    }
}
