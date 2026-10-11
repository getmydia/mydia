using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.Net;
using System.Text;
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

            if (!request.ConnectionKeepAlive)
            {
                headers.Add(("Connection", "close"));
            }

            var cookieHeader = cookies.GetCookieHeader((Uri)request.Url);
            if (cookieHeader.IsNotNullOrWhiteSpace())
            {
                headers.Add(("Cookie", cookieHeader));
            }

            // Only BasicNetworkCredential is mirrored. Upstream registers other
            // NetworkCredentials in a CredentialCache for the socket layer to
            // negotiate Basic/Digest, which has no equivalent here.
            if (request.Credentials is BasicNetworkCredential bc)
            {
                // Manually set header to avoid initial challenge response
                var authInfo = bc.UserName + ":" + bc.Password;
                authInfo = Convert.ToBase64String(Encoding.UTF8.GetBytes(authInfo));
                headers.Add(("Authorization", "Basic " + authInfo));
            }

            if (request.Headers != null)
            {
                AddRequestHeaders(headers, request.Headers, request.ContentData != null);
            }

            return new RawRequest(request.Method.ToString().ToUpperInvariant(), request.Url.FullUri, headers.ToArray(), request.ContentData);
        }

        // Mirrors ManagedHttpDispatcher.AddRequestHeaders (same cases, same order).
        private static void AddRequestHeaders(List<(string Name, string Value)> headers, HttpHeader requestHeaders, bool hasContent)
        {
            foreach (var header in requestHeaders)
            {
                switch (header.Key)
                {
                    case "Connection":
                        Replace(headers, "Connection", header.Value);
                        break;
                    case "Content-Length":
                    case "Content-Type":
                        // Upstream AddContentHeader ignores content headers without a body.
                        if (hasContent)
                        {
                            Replace(headers, header.Key, header.Value);
                        }

                        break;
                    case "Range":
                        throw new NotImplementedException();
                    case "User-Agent":
                        Replace(headers, "User-Agent", header.Value);
                        break;
                    case "Proxy-Connection":
                        throw new NotImplementedException();
                    default:
                        // Accept, Date, Expect, Host, If-Modified-Since, Referer,
                        // Transfer-Encoding and any other header are added as-is.
                        headers.Add((header.Key, header.Value));
                        break;
                }
            }
        }

        private static void Replace(List<(string Name, string Value)> headers, string name, string value)
        {
            headers.RemoveAll(h => h.Name.Equals(name, StringComparison.OrdinalIgnoreCase));
            headers.Add((name, value));
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
