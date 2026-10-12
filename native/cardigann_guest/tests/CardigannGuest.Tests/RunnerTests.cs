using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Mydia.CardigannGuest.Shim;
using Newtonsoft.Json.Linq;
using NzbDrone.Core.Indexers.Definitions.Cardigann.Exceptions;
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
            Assert.Equal(new DateTime(2031, 4, 2), first.PublishDate.ToUniversalTime().Date);

            var second = result.Releases[1];
            Assert.Equal("Glass Orchard S02E05 720p HDTV x264", second.Title);
            Assert.Equal("https://lantern.invalid/dl/102.torrent", second.DownloadUrl);
            Assert.Equal(7, ((TorrentInfo)second).Seeders);
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
        public void Capabilities_list_mapped_categories_and_search_modes()
        {
            var caps = JObject.Parse(Runner.Capabilities(Fixture("lantern-public.yml")));

            var categories = caps["Categories"].ToDictionary(c => (int)c["Id"], c => (string)c["Name"]);
            Assert.Equal("Movies", categories[2000]);
            Assert.Equal("TV", categories[5000]);
            Assert.True((bool)caps["SearchAvailable"]);
            Assert.True((bool)caps["MovieSearchAvailable"]);
            Assert.True((bool)caps["TvSearchAvailable"]);
            Assert.True((bool)caps["TvSearchSeasonAvailable"]);
            Assert.True((bool)caps["TvSearchEpAvailable"]);
            Assert.False((bool)caps["MovieSearchImdbAvailable"]);
        }

        [Theory]
        [InlineData("seeds")]
        [InlineData("1")]
        public void Select_setting_is_bound_by_option_key_or_index(string host)
        {
            var http = new FakeExchange().On("GET", "/search", _ => FakeExchange.Html(Fixture("lantern-search.html")));
            var q = new QueryInput("search", "harbor", Array.Empty<int>(), null, null, null, null, null, null, null);

            Runner.Search(Fixture("lantern-select.yml"), new Dictionary<string, string> { ["sort"] = host }, q, Empty, http);

            Assert.Contains("sort=seeds", http.Seen[0].Url);
        }

        [Fact]
        public void Select_setting_defaults_to_definition_default()
        {
            var http = new FakeExchange().On("GET", "/search", _ => FakeExchange.Html(Fixture("lantern-search.html")));
            var q = new QueryInput("search", "harbor", Array.Empty<int>(), null, null, null, null, null, null, null);

            Runner.Search(Fixture("lantern-select.yml"), new Dictionary<string, string>(), q, Empty, http);

            Assert.Contains("sort=new", http.Seen[0].Url);
        }

        private static readonly byte[] TorrentBytes = Encoding.ASCII.GetBytes(
            "d4:infod6:lengthi5e4:name1:a12:piece lengthi16384e6:pieces20:AAAAAAAAAAAAAAAAAAAAee");

        [Fact]
        public void Torrent_download_returns_bytes()
        {
            var http = new FakeExchange().On("GET", "/dl/101.torrent", _ => new RawResponse(200,
                new[] { ("Content-Type", "application/x-bittorrent") }, TorrentBytes));

            var result = Runner.Download(Fixture("lantern-public.yml"), new Dictionary<string, string>(),
                "https://lantern.invalid/dl/101.torrent", Empty, http);

            Assert.Equal(TorrentBytes, result.Bytes);
            Assert.Null(result.MagnetOrUrl);
        }

        [Fact]
        public void Download_redirecting_to_magnet_returns_the_magnet()
        {
            const string magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Paper+Harbor";
            var http = new FakeExchange().On("GET", "/dl/101.torrent", _ => new RawResponse(302,
                new[] { ("Location", magnet) }, Array.Empty<byte>()));

            var result = Runner.Download(Fixture("lantern-public.yml"), new Dictionary<string, string>(),
                "https://lantern.invalid/dl/101.torrent", Empty, http);

            Assert.Null(result.Bytes);
            Assert.Equal(magnet, result.MagnetOrUrl);
        }

        [Fact]
        public void Login_error_selector_raises_upstream_config_exception()
        {
            var http = new FakeExchange()
                .On("GET", "/login.php", _ => FakeExchange.Html(Fixture("quill-login-page.html")))
                .On("POST", "/takelogin.php", _ => FakeExchange.Html("<div class=\"error\">Bad password</div>"));
            var settings = new Dictionary<string, string> { ["username"] = "reader", ["password"] = "wrong" };

            var ex = Assert.Throws<CardigannConfigException>(
                () => Runner.Login(Fixture("quill-login.yml"), settings, Empty, null, null, http));

            Assert.Contains("Bad password", ex.Message);
        }

        [Fact]
        public void Captcha_login_asks_first_then_answers_without_refetching()
        {
            var http = new FakeExchange()
                .On("GET", "/login.php", _ => FakeExchange.Html(Fixture("quill-captcha-page.html"), ("Set-Cookie", "sid=pre1; Path=/")))
                .On("GET", "/captcha.png", _ => new RawResponse(200,
                    new[] { ("Content-Type", "image/png") }, new byte[] { 1, 2, 3 }))
                .On("POST", "/takelogin.php", _ => FakeExchange.Html("<a href=\"logout.php\">logout</a>", ("Set-Cookie", "sid=post2; Path=/")));
            var settings = new Dictionary<string, string> { ["username"] = "reader", ["password"] = "secret" };

            var first = Assert.IsType<LoginCaptcha>(
                Runner.Login(Fixture("quill-captcha.yml"), settings, Empty, null, null, http));
            Assert.Equal(new byte[] { 1, 2, 3 }, first.Image);
            Assert.Equal("image/png", first.ContentType);
            Assert.Equal("pre1", first.Session.Cookies["sid"]);
            var seenAfterFirst = http.Seen.Count;

            var second = Assert.IsType<LoginOk>(
                Runner.Login(Fixture("quill-captcha.yml"), settings, first.Session, "xk7", first.State, http));

            var later = http.Seen.Skip(seenAfterFirst).ToList();
            Assert.DoesNotContain(later, r => r.Method == "GET");
            var post = Assert.Single(later, r => r.Method == "POST");
            var form = Encoding.UTF8.GetString(post.Body);
            Assert.Contains("captcha=xk7", form);
            Assert.Contains("token=t0k", form);
            Assert.Contains(post.Headers, h => h.Name == "Cookie" && h.Value.Contains("sid=pre1"));
            Assert.Equal("post2", second.Session.Cookies["sid"]);
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
