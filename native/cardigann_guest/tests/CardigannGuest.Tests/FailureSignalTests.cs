using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using Mydia.CardigannGuest.Shim;
using Xunit;

namespace Mydia.CardigannGuest.Tests
{
    // Upstream swallows a failed search request as an empty page. These tests pin
    // the signal the guest adds so the host can tell a block from "no results".
    public class FailureSignalTests
    {
        private static string Fixture(string name) => File.ReadAllText(Path.Combine("fixtures", name));
        private static readonly Session Empty = new(new Dictionary<string, string>(), null);
        private static readonly QueryInput Query =
            new("search", "harbor", Array.Empty<int>(), null, null, null, null, null, null, null);

        private static SearchOutput Search(IExchange http, Dictionary<string, string> settings = null) =>
            Runner.Search(Fixture("lantern-public.yml"), settings ?? new Dictionary<string, string>(), Query, Empty, http);

        private static RawResponse Status(int code, string body = "", params (string, string)[] headers) =>
            new(code, headers, System.Text.Encoding.UTF8.GetBytes(body));

        [Fact]
        public void A_good_answer_is_not_a_failure()
        {
            var http = new FakeExchange().On("GET", "/search", _ => FakeExchange.Html(Fixture("lantern-search.html")));

            var result = Search(http);

            Assert.Equal(2, result.Releases.Count);
            Assert.False(result.RequestFailed);
        }

        [Fact]
        public void An_empty_page_with_status_200_is_not_a_failure()
        {
            var http = new FakeExchange().On("GET", "/search", _ => FakeExchange.Html("<html><body></body></html>"));

            var result = Search(http);

            Assert.Empty(result.Releases);
            Assert.False(result.RequestFailed);
        }

        [Fact]
        public void A_cloudflare_block_is_a_failure()
        {
            var http = new FakeExchange().On("GET", "/search", _ => Status(403,
                "<html><head><title>Just a moment...</title></head></html>", ("Server", "cloudflare")));

            var result = Search(http);

            Assert.Empty(result.Releases);
            Assert.True(result.RequestFailed);
        }

        [Theory]
        [InlineData(403)]
        [InlineData(404)]
        [InlineData(429)]
        public void A_client_error_status_is_a_failure(int status)
        {
            var http = new FakeExchange().On("GET", "/search", _ => Status(status, "nope"));

            var result = Search(http);

            Assert.Empty(result.Releases);
            Assert.True(result.RequestFailed);
        }

        [Fact]
        public void A_transport_error_is_a_failure()
        {
            var http = new ThrowingExchange(new HttpRequestException("connect: connection refused"));

            var result = Search(http);

            Assert.Empty(result.Releases);
            Assert.True(result.RequestFailed);
        }

        [Theory]
        [InlineData(500)]
        [InlineData(502)]
        [InlineData(503)]
        [InlineData(504)]
        public void A_persistent_server_error_is_retried_then_swallowed_as_upstream_does(int status)
        {
            var http = new FakeExchange().On("GET", "/search", _ => Status(status, "down"));

            var result = Search(http);

            Assert.Empty(result.Releases);
            Assert.True(result.RequestFailed);
            Assert.Equal(status, result.FailedStatus);
            Assert.Equal(3, http.Seen.Count);
        }

        [Fact]
        public void A_transient_503_followed_by_a_good_answer_returns_results()
        {
            var calls = 0;
            var http = new FakeExchange().On("GET", "/search", _ =>
                ++calls == 1 ? Status(503, "busy") : FakeExchange.Html(Fixture("lantern-search.html")));

            var result = Search(http);

            Assert.Equal(2, result.Releases.Count);
            Assert.Equal(2, http.Seen.Count);
            // The retry worked, so nothing was swallowed.
            Assert.False(result.RequestFailed);
            Assert.Null(result.FailedStatus);
        }

        [Fact]
        public void A_transient_503_followed_by_an_empty_200_is_no_results_not_a_failure()
        {
            var calls = 0;
            var http = new FakeExchange().On("GET", "/search", _ =>
                ++calls == 1 ? Status(503, "busy") : FakeExchange.Html("<html><body></body></html>"));

            var result = Search(http);

            Assert.Empty(result.Releases);
            Assert.False(result.RequestFailed);
            Assert.Null(result.FailedStatus);
            Assert.Equal(2, http.Seen.Count);
        }

        [Fact]
        public void The_retry_waits_between_attempts()
        {
            var waits = new List<TimeSpan>();
            var before = BlockingTimeProvider.Sleep;
            BlockingTimeProvider.Sleep = waits.Add;
            try
            {
                Search(new FakeExchange().On("GET", "/search", _ => Status(503, "down")));
            }
            finally
            {
                BlockingTimeProvider.Sleep = before;
            }

            Assert.Equal(2, waits.Count);
            Assert.All(waits, w => Assert.True(w > TimeSpan.Zero));
        }

        [Fact]
        public void A_cloudflare_challenge_served_as_503_is_detected_as_cloudflare()
        {
            var outcome = new RequestOutcome();
            var http = new FakeExchange().On("GET", "/search", _ => Status(503,
                "<html><head><title>Just a moment...</title></head></html>", ("Server", "cloudflare")));
            var request = new NzbDrone.Common.Http.HttpRequest("https://lantern.invalid/search");

            new ExchangeDispatcher(http, outcome).GetResponseAsync(request, new System.Net.CookieContainer())
                .GetAwaiter().GetResult();

            Assert.True(outcome.Cloudflare);
            Assert.Equal(503, outcome.FailedStatus);
        }

        [Fact]
        public void A_cloudflare_challenge_served_as_503_ends_the_search_empty_and_failed()
        {
            var http = new FakeExchange().On("GET", "/search", _ => Status(503,
                "<html><head><title>Just a moment...</title></head></html>", ("Server", "cloudflare")));

            var result = Search(http);

            Assert.Empty(result.Releases);
            Assert.True(result.RequestFailed);
            Assert.Equal(503, result.FailedStatus);
        }

        [Fact]
        public void A_login_answered_with_a_server_error_is_read_for_its_error_selector()
        {
            var http = new FakeExchange()
                .On("GET", "/login.php", _ => FakeExchange.Html(Fixture("quill-login-page.html")))
                .On("POST", "/takelogin.php", _ => Status(500, "<div class=\"error\">Server busy</div>"));
            var settings = new Dictionary<string, string> { ["username"] = "reader", ["password"] = "secret" };

            var ex = Assert.Throws<NzbDrone.Core.Indexers.Definitions.Cardigann.Exceptions.CardigannConfigException>(
                () => Runner.Login(Fixture("quill-login.yml"), settings, Empty, null, null, http));

            Assert.Contains("Server busy", ex.Message);
            Assert.Single(http.Seen, r => r.Method == "POST");
        }

        [Fact]
        public void The_base_url_setting_picks_the_mirror()
        {
            var http = new FakeExchange().On("GET", "/search", _ => FakeExchange.Html(Fixture("lantern-search.html")));
            var settings = new Dictionary<string, string> { [Runner.BaseUrlSettingKey] = "https://mirror.invalid/" };

            var result = Search(http, settings);

            Assert.Equal(2, result.Releases.Count);
            Assert.All(http.Seen, r => Assert.StartsWith("https://mirror.invalid/", r.Url));
        }

        [Fact]
        public void Without_a_base_url_setting_the_first_link_is_used()
        {
            var http = new FakeExchange().On("GET", "/search", _ => FakeExchange.Html(Fixture("lantern-search.html")));

            Search(http);

            Assert.All(http.Seen, r => Assert.StartsWith("https://lantern.invalid/", r.Url));
        }

        private sealed class ThrowingExchange : IExchange
        {
            private readonly Exception _error;

            public ThrowingExchange(Exception error) => _error = error;

            public RawResponse Send(RawRequest request) => throw _error;
        }
    }
}
