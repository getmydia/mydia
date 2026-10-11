using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Mydia.CardigannGuest.Shim;
using NzbDrone.Core.Parser.Model;
using Xunit;

namespace Mydia.CardigannGuest.Tests
{
    public class RunnerTests
    {
        private static string Fixture(string name) => File.ReadAllText(Path.Combine("fixtures", name));
        private static readonly Session Empty = new(new Dictionary<string, string>(), null);

        [Fact]
        public void Public_search_returns_parsed_rows()
        {
            var http = new FakeExchange().On("GET", "/search", _ => FakeExchange.Html(Fixture("lantern-search.html")));
            var q = new QueryInput("search", "harbor", Array.Empty<int>(), null, null, null, null, null, null, null);

            var result = Runner.Search(Fixture("lantern-public.yml"), new Dictionary<string, string>(), q, Empty, http);

            Assert.Equal(2, result.Releases.Count);
            var first = result.Releases[0];
            Assert.Equal("Paper Harbor 2031 1080p WEB-DL x264", first.Title);
            Assert.Equal("https://lantern.invalid/dl/101.torrent", first.DownloadUrl);
            Assert.Equal(1610612736L, first.Size);
            Assert.Equal(42, ((TorrentInfo)first).Seeders);
            Assert.Contains("q=harbor", http.Seen[0].Url);
        }

        [Fact]
        public void Form_login_posts_credentials_and_returns_session_cookie()
        {
            var http = new FakeExchange()
                .On("GET", "/login.php", _ => FakeExchange.Html(Fixture("quill-login-page.html")))
                .On("POST", "/takelogin.php", _ => new RawResponse(302,
                    new[] { ("Location", "/index.php"), ("Set-Cookie", "sid=abc123; Path=/") }, Array.Empty<byte>()))
                .On("GET", "/index.php", _ => FakeExchange.Html("<a href=\"logout.php\">logout</a>"));

            var settings = new Dictionary<string, string> { ["username"] = "reader", ["password"] = "secret" };
            var result = Runner.Login(Fixture("quill-login.yml"), settings, Empty, null, null, http);

            var ok = Assert.IsType<LoginOk>(result);
            Assert.Equal("abc123", ok.Session.Cookies["sid"]);
            var post = http.Seen.Single(r => r.Method == "POST");
            var form = Encoding.UTF8.GetString(post.Body);
            Assert.Contains("username=reader", form);
            Assert.Contains("token=t0k", form);
        }

        [Fact]
        public void Capabilities_serialise_to_json_without_http()
        {
            var json = Runner.Capabilities(Fixture("lantern-public.yml"));

            // Newtonsoft writes upstream's enums as numbers, so check structure, not names.
            Assert.StartsWith("{\"SearchParams\":", json);
            Assert.Contains("TvSearchParams", json);
        }

        [Fact]
        public void Search_with_stored_session_sends_cookie_and_skips_login()
        {
            var http = new FakeExchange().On("GET", "/search", _ => FakeExchange.Html(Fixture("quill-search.html")));
            var session = new Session(new Dictionary<string, string> { ["sid"] = "abc123" }, DateTime.UtcNow.AddDays(1));
            var q = new QueryInput("search", "copper", Array.Empty<int>(), null, null, null, null, null, null, null);
            var settings = new Dictionary<string, string> { ["username"] = "reader", ["password"] = "secret" };

            var result = Runner.Search(Fixture("quill-login.yml"), settings, q, session, http);

            Assert.Single(result.Releases);
            Assert.DoesNotContain(http.Seen, r => r.Url.Contains("login.php"));
            Assert.Contains(http.Seen[0].Headers, h => h.Name == "Cookie" && h.Value.Contains("sid=abc123"));
        }
    }
}
