using System.Net;
using System.Threading.Tasks;
using NzbDrone.Common.Http;
using NzbDrone.Common.Http.Dispatchers;

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

    public sealed class ExchangeDispatcher : IHttpDispatcher
    {
        private readonly IExchange _exchange;

        public ExchangeDispatcher(IExchange exchange) => _exchange = exchange;

        public Task<HttpResponse> GetResponseAsync(HttpRequest request, CookieContainer cookies)
        {
            var raw = _exchange.Send(RequestMapping.ToRaw(request, cookies));
            return Task.FromResult(RequestMapping.FromRaw(request, raw, cookies));
        }
    }
}
