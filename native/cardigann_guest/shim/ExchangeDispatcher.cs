using System;
using System.Net;
using System.Net.Http;
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

        // The first server error (5xx or 408) seen, which upstream would retry.
        public int? ServerErrorStatus { get; private set; }

        public void MarkFailed() => Failed = true;

        public void MarkServerError(int status)
        {
            Failed = true;
            ServerErrorStatus ??= status;
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

            // Upstream retries a server error twice behind a timer delay, and the
            // guest has no event loop to wake that wait (it ends in a
            // PlatformNotSupportedException). The retry would only repeat the
            // request the host just made, so the status is raised as the error
            // it is, naming the status, and upstream's own handling takes over.
            if (raw.Status >= 500 || raw.Status == (int)HttpStatusCode.RequestTimeout)
            {
                _outcome.MarkServerError(raw.Status);
                throw new HttpRequestException(
                    $"Tracker answered HTTP {raw.Status} for {request.Url.Host}", null, (HttpStatusCode)raw.Status);
            }

            if (raw.Status >= 400 || CloudFlareDetectionService.IsCloudflareProtected(response))
            {
                _outcome.MarkFailed();
            }

            return Task.FromResult(response);
        }
    }
}
