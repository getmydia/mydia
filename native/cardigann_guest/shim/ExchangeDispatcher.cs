using System;
using System.Collections.Generic;
using System.Linq;
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
        // Requests whose latest answer was a failure, in the order they failed. A
        // request that is retried and then succeeds is taken off the list: only
        // what upstream ends up swallowing counts.
        private readonly List<(string Key, int? Status, bool Cloudflare)> _failures = new();

        public bool Failed => _failures.Count > 0;

        // The status of the last failed response of 400 or more, null when none
        // was received (a transport failure, or no failure at all).
        public int? FailedStatus => _failures.LastOrDefault(f => f.Status.HasValue).Status;

        // A response that upstream's CloudFlareDetectionService calls a challenge.
        public bool Cloudflare => _failures.Any(f => f.Cloudflare);

        public void MarkFailed(string key) => Replace(key, null, false);

        public void MarkResponse(string key, int status, bool cloudflare) => Replace(key, status, cloudflare);

        public void MarkSucceeded(string key) => _failures.RemoveAll(f => f.Key == key);

        private void Replace(string key, int? status, bool cloudflare)
        {
            MarkSucceeded(key);
            _failures.Add((key, status, cloudflare));
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
            var key = request.Method + " " + request.Url.FullUri;
            RawResponse raw;
            try
            {
                raw = _exchange.Send(RequestMapping.ToRaw(request, cookies));
            }
            catch (Exception)
            {
                _outcome.MarkFailed(key);
                throw;
            }

            var response = RequestMapping.FromRaw(request, raw, cookies);
            var cloudflare = CloudFlareDetectionService.IsCloudflareProtected(response);

            // Recorded only: upstream decides what a bad response means (retry a
            // server error, raise a Cloudflare challenge, read a login error).
            if (raw.Status >= 400 || cloudflare)
            {
                _outcome.MarkResponse(key, raw.Status, cloudflare);
            }
            else
            {
                _outcome.MarkSucceeded(key);
            }

            return Task.FromResult(response);
        }
    }
}
