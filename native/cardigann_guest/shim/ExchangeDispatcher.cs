using System;
using System.Net;
using System.Threading.Tasks;
using NzbDrone.Common.Http;
using NzbDrone.Common.Http.Dispatchers;
using NzbDrone.Core.Http.CloudFlare;

namespace Mydia.CardigannGuest.Shim
{
    // One HTTP exchange, no redirect following: Prowlarr's HttpClient follows
    // redirects itself with its domain-scoped CookieContainer.
    public interface IExchange
    {
        RawResponse Send(RawRequest request);
    }

    public sealed record RawRequest(string Method, string Url, (string Name, string Value)[] Headers, byte[] Body);

    public sealed record RawResponse(int Status, (string Name, string Value)[] Headers, byte[] Body);

    // What went wrong with the requests of one call. Upstream swallows a failed
    // search request as an empty page, so this is the only way the host can tell
    // "the tracker has nothing" from "the tracker could not be asked".
    public sealed class RequestOutcome
    {
        public bool Failed { get; private set; }

        // The status of the last response of 400 or more, null when none was
        // received (a transport failure, or no failure at all).
        public int? FailedStatus { get; private set; }

        // A response that upstream's CloudFlareDetectionService calls a challenge.
        public bool Cloudflare { get; private set; }

        public void MarkFailed() => Failed = true;

        public void MarkResponse(int status, bool cloudflare)
        {
            Failed = true;
            FailedStatus = status;
            Cloudflare |= cloudflare;
        }
    }

    public sealed class ExchangeDispatcher : IHttpDispatcher
    {
        private readonly IExchange _exchange;
        private readonly RequestOutcome _outcome;

        public ExchangeDispatcher(IExchange exchange, RequestOutcome outcome = null)
        {
            _exchange = exchange;
            _outcome = outcome ?? new RequestOutcome();
        }

        public Task<HttpResponse> GetResponseAsync(HttpRequest request, CookieContainer cookies)
        {
            RawResponse raw;
            try
            {
                raw = _exchange.Send(RequestMapping.ToRaw(request, cookies));
            }
            catch (Exception)
            {
                _outcome.MarkFailed();
                throw;
            }

            var response = RequestMapping.FromRaw(request, raw, cookies);
            var cloudflare = CloudFlareDetectionService.IsCloudflareProtected(response);

            // Recorded only: upstream decides what a bad response means (retry a
            // server error, raise a Cloudflare challenge, read a login error).
            if (raw.Status >= 400 || cloudflare)
            {
                _outcome.MarkResponse(raw.Status, cloudflare);
            }

            return Task.FromResult(response);
        }
    }
}
