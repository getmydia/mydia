using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Mydia.CardigannGuest.Shim;

namespace Mydia.CardigannGuest.Tests
{
    public sealed class FakeExchange : IExchange
    {
        private readonly List<((string Method, string Prefix) Key, Func<RawRequest, RawResponse> Handler)> _routes = new();
        public List<RawRequest> Seen { get; } = new();

        public FakeExchange On(string method, string pathAndQueryPrefix, Func<RawRequest, RawResponse> handler)
        {
            _routes.Add(((method, pathAndQueryPrefix), handler));
            return this;
        }

        public RawResponse Send(RawRequest request)
        {
            Seen.Add(request);
            var uri = new Uri(request.Url);
            foreach (var ((method, prefix), handler) in _routes)
            {
                if (method == request.Method && uri.PathAndQuery.StartsWith(prefix, StringComparison.Ordinal))
                {
                    return handler(request);
                }
            }

            return new RawResponse(404, Array.Empty<(string, string)>(), Array.Empty<byte>());
        }

        public static RawResponse Html(string body, params (string, string)[] headers) =>
            new(200, headers.Append(("Content-Type", "text/html; charset=utf-8")).ToArray(), Encoding.UTF8.GetBytes(body));
    }
}
