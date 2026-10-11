using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Net;
using NzbDrone.Common.Extensions;
using NzbDrone.Common.Http;

namespace Mydia.CardigannGuest.Shim
{
    // Mirrors what upstream ManagedHttpDispatcher.GetResponseAsync does around
    // the socket call (user agent, Cookie header, Set-Cookie handling, response
    // header and cookie collection), minus the socket, proxy and TLS code.
    public static class RequestMapping
    {
        // ManagedHttpDispatcher takes this from UserAgentBuilder, which needs OsInfo.
        public const string UserAgent = "Prowlarr/2.6.5.5623 (linux)";
        public const string UserAgentSimplified = "Prowlarr/2.6";

        public static RawRequest ToRaw(HttpRequest request, CookieContainer cookies)
        {
            var headers = new List<(string Name, string Value)>
            {
                ("User-Agent", request.UseSimplifiedUserAgent ? UserAgentSimplified : UserAgent)
            };

            var cookieHeader = cookies.GetCookieHeader((Uri)request.Url);
            if (cookieHeader.IsNotNullOrWhiteSpace())
            {
                headers.Add(("Cookie", cookieHeader));
            }

            if (request.Headers != null)
            {
                foreach (var header in request.Headers)
                {
                    // Request headers override the defaults above, as in the upstream dispatcher.
                    if (header.Key.Equals("User-Agent", StringComparison.OrdinalIgnoreCase))
                    {
                        headers.RemoveAll(h => h.Name.Equals("User-Agent", StringComparison.OrdinalIgnoreCase));
                    }

                    headers.Add((header.Key, header.Value));
                }
            }

            return new RawRequest(request.Method.ToString().ToUpperInvariant(), request.Url.FullUri, headers.ToArray(), request.ContentData);
        }

        public static HttpResponse FromRaw(HttpRequest request, RawResponse raw, CookieContainer cookies)
        {
            var uri = (Uri)request.Url;
            var headers = new NameValueCollection();

            foreach (var (name, value) in raw.Headers)
            {
                headers.Add(name, value);

                if (name.Equals("Set-Cookie", StringComparison.OrdinalIgnoreCase))
                {
                    try
                    {
                        cookies.SetCookies(uri, value);
                    }
                    catch
                    {
                        // Ignore invalid cookies
                    }
                }
            }

            var cookieCollection = cookies.GetCookies(uri);

            return new HttpResponse(request, new HttpHeader(headers), cookieCollection, raw.Body, 0, (HttpStatusCode)raw.Status);
        }
    }
}
