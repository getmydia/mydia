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
    // The same fixtures drive test/mydia/indexers/cardigann/wasm/engine_test.exs
    // under Wasmex. The assertions here are the oracle for that file: upstream's
    // engine on plain .NET and the wasm build must agree.
    public class FixtureTests
    {
        private static string Fixture(string name) => File.ReadAllText(Path.Combine("fixtures", name));
        private static readonly Session Empty = new(new Dictionary<string, string>(), null);

        private static QueryInput Query(string term) =>
            new("search", term, Array.Empty<int>(), null, null, null, null, null, null, null);

        private static RawResponse Body(string body, string contentType) =>
            new(200, new[] { ("Content-Type", contentType) }, Encoding.UTF8.GetBytes(body));

        [Fact]
        public void Json_rows_are_parsed()
        {
            var http = new FakeExchange().On("GET", "/api/search", _ => Body(Fixture("ember-search.json"), "application/json"));

            var result = Runner.Search(Fixture("ember-json.yml"), new Dictionary<string, string>(), Query("meadow"), Empty, http);

            var release = Assert.Single(result.Releases);
            Assert.Equal("Tin Meadow 2032 1080p BluRay x265", release.Title);
            Assert.Equal("https://ember.invalid/dl/9.torrent", release.DownloadUrl);
            Assert.Equal(2147483648L, release.Size);
            Assert.Equal(11, ((TorrentInfo)release).Seeders);
            Assert.Equal(14, ((TorrentInfo)release).Peers);
        }

        [Theory]
        [InlineData(200, "text/html", "<html>nope</html>")]
        [InlineData(200, "application/json", "{not json")]
        [InlineData(200, "application/json", "{\"data\":{\"items\":\"oops\"}}")]
        [InlineData(200, "application/json", "")]
        [InlineData(500, "text/html", "boom")]
        public void A_response_that_cannot_be_read_yields_no_releases(int status, string contentType, string text)
        {
            // Upstream logs the failure and returns an empty page rather than throwing.
            var http = new FakeExchange().On("GET", "/api/search",
                _ => new RawResponse(status, new[] { ("Content-Type", contentType) }, Encoding.UTF8.GetBytes(text)));

            var result = Runner.Search(Fixture("ember-json.yml"), new Dictionary<string, string>(), Query("x"), Empty, http);

            Assert.Empty(result.Releases);
        }

        [Fact]
        public void Xml_rows_are_parsed()
        {
            var http = new FakeExchange().On("GET", "/feed.xml", _ => Body(Fixture("slate-search.xml"), "application/xml"));

            var result = Runner.Search(Fixture("slate-xml.yml"), new Dictionary<string, string>(), Query("salt"), Empty, http);

            Assert.Equal(2, result.Releases.Count);
            var first = result.Releases[0];
            Assert.Equal("Salt Meridian 2033 720p WEB-DL x264", first.Title);
            Assert.Equal("https://slate.invalid/dl/31.torrent", first.DownloadUrl);
            Assert.Equal(1073741824L, first.Size);
            Assert.Equal(25, ((TorrentInfo)first).Seeders);
            Assert.Equal(29, ((TorrentInfo)first).Peers);
            Assert.Equal("Hollow Pines S01E02 1080p WEB-DL x264", result.Releases[1].Title);
        }

        private static readonly byte[] TorrentBytes = Encoding.ASCII.GetBytes(
            "d4:infod6:lengthi5e4:name1:a12:piece lengthi16384e6:pieces20:AAAAAAAAAAAAAAAAAAAAee");

        [Fact]
        public void Download_before_is_requested_ahead_of_the_download()
        {
            var http = new FakeExchange()
                .On("GET", "/before", _ => FakeExchange.Html("ok"))
                .On("GET", "/dl/1.torrent", _ =>
                    new RawResponse(200, new[] { ("Content-Type", "application/x-bittorrent") }, TorrentBytes));

            var result = Runner.Download(Fixture("moss-download-before.yml"), new Dictionary<string, string>(),
                "https://moss.invalid/dl/1.torrent", Empty, http);

            Assert.Equal(TorrentBytes, result.Bytes);
            Assert.Equal(new[] { "/before", "/dl/1.torrent" }, http.Seen.Select(r => new Uri(r.Url).AbsolutePath).ToArray());
        }

        [Fact]
        public void Every_search_path_is_requested()
        {
            var http = new FakeExchange()
                .On("GET", "/movies", _ => FakeExchange.Html(Fixture("fern-movies.html")))
                .On("GET", "/shows", _ => FakeExchange.Html(Fixture("fern-shows.html")));

            var result = Runner.Search(Fixture("fern-paged.yml"), new Dictionary<string, string>(), Query("x"), Empty, http);

            Assert.Equal(
                new[] { "Reed Lighthouse 2034 1080p BluRay x264", "Quartz Valley S03E01 720p HDTV x264" },
                result.Releases.Select(r => r.Title).ToArray());
            Assert.Equal(2, http.Seen.Count);
        }

        [Fact]
        public void Keywordsfilters_rewrite_the_query_before_it_is_sent()
        {
            var http = new FakeExchange().On("GET", "/search", _ => FakeExchange.Html("<html></html>"));

            Runner.Search(Fixture("birch-keywordsfilters.yml"), new Dictionary<string, string>(), Query("Cedar's Edge: Part Two!"), Empty, http);

            Assert.Equal("?q=cedars+edge+part+two", new Uri(http.Seen[0].Url).Query);
        }

        [Theory]
        [InlineData("")]
        [InlineData("abc")]
        [InlineData("Movies/HD")]
        [InlineData("a string of exactly fifty-five characters, give or tak")]
        [InlineData("a string long enough to need a second 64 byte block of input, yes")]
        public void Managed_sha1_matches_the_framework(string text)
        {
            var bytes = Encoding.UTF8.GetBytes(text);
            Assert.Equal(System.Security.Cryptography.SHA1.HashData(bytes), ManagedSha1.Hash(bytes));
        }

        [Fact]
        public void String_tracker_categories_get_stable_custom_ids()
        {
            var caps = Newtonsoft.Json.Linq.JObject.Parse(Runner.Capabilities(Fixture("cedar-stringcats.yml")));

            var ids = caps["Categories"].SelectMany(c => c["SubCategories"].Select(sc => (int)sc["Id"]).Append((int)c["Id"])).ToList();
            Assert.Contains(132084, ids); // 100000 + the first two SHA1 bytes of "Movies/HD", little endian
            Assert.Contains(129396, ids); // the same for "TV/Packs"
        }

        [Fact]
        public void Torrent_download_rejects_an_html_page()
        {
            var http = new FakeExchange().On("GET", "/dl/1.torrent", _ => FakeExchange.Html("<html>login</html>"));

            var ex = Assert.ThrowsAny<Exception>(() => Runner.Download(Fixture("lantern-public.yml"),
                new Dictionary<string, string>(), "https://lantern.invalid/dl/1.torrent", Empty, http));

            Assert.Contains("Site responded with html content", ex.ToString());
        }

        [Fact]
        public void Torrent_download_rejects_a_body_that_is_not_bencode()
        {
            var http = new FakeExchange().On("GET", "/dl/1.torrent", _ => new RawResponse(200,
                new[] { ("Content-Type", "application/x-bittorrent") }, Encoding.ASCII.GetBytes("not a torrent")));

            var ex = Assert.ThrowsAny<Exception>(() => Runner.Download(Fixture("lantern-public.yml"),
                new Dictionary<string, string>(), "https://lantern.invalid/dl/1.torrent", Empty, http));

            Assert.Contains("Invalid torrent file contents", ex.ToString());
        }

        [Fact]
        public void Dotnet_only_regex_constructs_work_in_field_filters()
        {
            var http = new FakeExchange().On("GET", "/search", _ => FakeExchange.Html(Fixture("alder-search.html")));

            var result = Runner.Search(Fixture("alder-dotnet-regex.yml"), new Dictionary<string, string>(), Query("birch"), Empty, http);

            var release = Assert.Single(result.Releases);
            Assert.Equal("Birch Hollow 1080p BluRay x264", release.Title);
            Assert.Equal(2684354560L, release.Size);
        }
    }
}
