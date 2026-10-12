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
        public void A_server_error_is_a_clean_error_naming_the_status_and_is_not_retried(int status)
        {
            var http = new FakeExchange().On("GET", "/search", _ => Status(status, "down"));

            var error = Assert.Throws<HttpRequestException>(() => Search(http));

            Assert.Contains($"HTTP {status}", error.Message);
            Assert.IsNotType<PlatformNotSupportedException>(error);
            Assert.Single(http.Seen);
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
