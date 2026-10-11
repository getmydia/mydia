using System;
using System.Collections.Generic;
using NzbDrone.Core.Parser.Model;
using NzbDrone.Core.ThingiProvider.Status;

namespace NzbDrone.Core.ThingiProvider.Status
{
    // Interface half of upstream ProviderStatusServiceBase.cs.
    public interface IProviderStatusServiceBase<TModel>
        where TModel : ProviderStatusBase, new()
    {
        List<TModel> GetBlockedProviders();
        void RecordSuccess(int providerId);
        void RecordFailure(int providerId, TimeSpan minimumBackOff = default(TimeSpan));
        void RecordConnectionFailure(int providerId);
    }
}

namespace NzbDrone.Core.Indexers
{
    // Interface half of upstream IndexerStatusService.cs.
    public interface IIndexerStatusService : IProviderStatusServiceBase<IndexerStatus>
    {
        ReleaseInfo GetLastRssSyncReleaseInfo(int indexerId);
        IDictionary<string, string> GetIndexerCookies(int indexerId);
        DateTime GetIndexerCookiesExpirationDate(int indexerId);

        void UpdateRssSyncStatus(int indexerId, ReleaseInfo releaseInfo);
        void UpdateCookies(int indexerId, IDictionary<string, string> cookies, DateTime? expiration);
    }

    // Replaces the database-backed IndexerStatusService. One instance per call;
    // the host seeds cookies from the stored session and reads them back after.
    public sealed class CallIndexerStatusService : IIndexerStatusService
    {
        public IDictionary<string, string> Cookies { get; private set; } = new Dictionary<string, string>();
        public DateTime? CookiesExpiration { get; private set; }
        public bool Changed { get; private set; }

        public CallIndexerStatusService(IDictionary<string, string> cookies, DateTime? expiration)
        {
            Cookies = cookies ?? new Dictionary<string, string>();
            CookiesExpiration = expiration;
        }

        public IDictionary<string, string> GetIndexerCookies(int indexerId) => Cookies;

        public DateTime GetIndexerCookiesExpirationDate(int indexerId) =>
            CookiesExpiration ?? DateTime.Now + TimeSpan.FromDays(30);

        public void UpdateCookies(int indexerId, IDictionary<string, string> cookies, DateTime? expiration)
        {
            Cookies = cookies ?? new Dictionary<string, string>();
            CookiesExpiration = expiration;
            Changed = true;
        }

        public ReleaseInfo GetLastRssSyncReleaseInfo(int indexerId) => null;

        public void UpdateRssSyncStatus(int indexerId, ReleaseInfo releaseInfo)
        {
        }

        public List<IndexerStatus> GetBlockedProviders() => new List<IndexerStatus>();

        public void RecordSuccess(int indexerId)
        {
        }

        public void RecordFailure(int indexerId, TimeSpan minimumBackOff = default)
        {
        }

        public void RecordConnectionFailure(int indexerId)
        {
        }
    }
}
