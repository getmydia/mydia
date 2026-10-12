using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Text;
using Mydia.CardigannGuest.Shim;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using NLog;
using NzbDrone.Common.Cache;
using NzbDrone.Common.Http;
using NzbDrone.Core.IndexerSearch.Definitions;
using NzbDrone.Core.Indexers;
using NzbDrone.Core.Indexers.Definitions.Cardigann;
using NzbDrone.Core.IndexerVersions;
using NzbDrone.Core.Parser.Model;

namespace Mydia.CardigannGuest
{
    public sealed record Session(IDictionary<string, string> Cookies, DateTime? Expires);

    public sealed record QueryInput(string Kind, string Term, int[] Categories, string ImdbId, int? TmdbId,
                                    int? TvdbId, int? Season, string Episode, int? Limit, int? Offset);

    public sealed record SearchOutput(IList<ReleaseInfo> Releases, Session Session, bool SessionChanged, bool RequestFailed, int? FailedStatus);

    public sealed record DownloadOutput(byte[] Bytes, string MagnetOrUrl, Session Session);

    public abstract record LoginOutput(Session Session);

    public sealed record LoginOk(Session Session) : LoginOutput(Session);

    public sealed record LoginCaptcha(Session Session, byte[] Image, string ContentType, string State) : LoginOutput(Session);

    // Stateless per-call entry points. Each call builds the object graph that
    // Prowlarr's dependency injection would build, runs one upstream operation
    // and returns the session cookies for the host to store.
    public static class Runner
    {
        // CardigannRequestGenerator reads the captcha answer under this exact key.
        private const string CaptchaSettingKey = "CAPTCHA";

        // The host picks the tracker mirror with this setting. It is Prowlarr's
        // own BaseUrl setting (read by ResolveSiteLink), not a definition field.
        public const string BaseUrlSettingKey = "baseUrl";

        // Prowlarr registers the code page encodings at startup (Bootstrap.cs);
        // trackers declare windows-1251, gb2312, shift_jis and similar. Without
        // the provider, Encoding.GetEncoding throws for every one of them.
        static Runner()
        {
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        }

        private sealed class Graph
        {
            public Cardigann Indexer;
            public IndexerHttpClient Client;
            public CallIndexerStatusService Status;
            public SingleDefinitionService Defs;
            public CacheManager Cache;
            public RequestOutcome Outcome;
        }

        private sealed class ThrowingExchange : IExchange
        {
            public RawResponse Send(RawRequest request) =>
                throw new InvalidOperationException("No HTTP is available for this call");
        }

        private static Graph Build(string yaml, IDictionary<string, string> settings, Session session, IExchange http)
        {
            var defs = new SingleDefinitionService(yaml);
            var logger = LogManager.GetLogger("Cardigann");
            var cache = new CacheManager();
            var status = new CallIndexerStatusService(
                new Dictionary<string, string>(session?.Cookies ?? new Dictionary<string, string>()),
                session?.Expires);
            var outcome = new RequestOutcome();
            var client = new IndexerHttpClient(
                new NoProxyFactory(),
                Array.Empty<IHttpRequestInterceptor>(),
                cache,
                new NoRateLimitService(),
                new ExchangeDispatcher(http, outcome),
                logger);

            var indexer = new Cardigann(defs, client, new NullEventAggregator(), status, new CallConfigService(), cache, logger);

            // The same definition upstream builds for its indexer list, with the
            // user's settings in ExtraFieldData as the settings binding stores them.
            var definition = indexer.DefaultDefinitions.Cast<IndexerDefinition>().First();
            definition.Id = 1;
            var extra = ((CardigannSettings)definition.Settings).ExtraFieldData;
            var fields = defs.GetCachedDefinition(defs.FileKey).Settings ?? new List<SettingsField>();
            foreach (var (key, value) in settings ?? new Dictionary<string, string>())
            {
                if (key == BaseUrlSettingKey)
                {
                    ((CardigannSettings)definition.Settings).BaseUrl = value;
                    continue;
                }

                var field = fields.FirstOrDefault(f => f.Name == key);
                extra[key] = field?.Type == "select" ? SelectIndex(field, value) : value;
            }

            indexer.Definition = definition;

            return new Graph { Indexer = indexer, Status = status, Defs = defs, Cache = cache, Client = client, Outcome = outcome };
        }

        // CardigannBase.GetBaseTemplateVariables reads a select value as the long
        // index into the options sorted by key. The host sends either the option
        // key or that index as a string.
        private static object SelectIndex(SettingsField field, string value)
        {
            var keys = (field.Options ?? new Dictionary<string, string>()).Keys.OrderBy(k => k).ToList();
            var byKey = keys.IndexOf(value);
            if (byKey >= 0)
            {
                return (long)byKey;
            }

            if (long.TryParse(value, out var index))
            {
                return index;
            }

            throw new ArgumentException($"Setting {field.Name}: '{value}' is not one of the options");
        }

        private static Session SessionOf(Graph g) => new Session(g.Status.Cookies, g.Status.CookiesExpiration);

        public static string Capabilities(string yaml)
        {
            var g = Build(yaml, null, null, new ThrowingExchange());
            var caps = g.Indexer.GetCapabilities();

            // Newtonsoft sees no public members on IndexerCapabilitiesCategories
            // (its lists are private) and writes {}, so the category tree is
            // projected explicitly.
            var json = JObject.FromObject(caps);
            json["Categories"] = JArray.FromObject(caps.Categories.GetTorznabCategoryTree()
                .Select(c => new
                {
                    c.Id,
                    c.Name,
                    SubCategories = c.SubCategories.Select(sc => new { sc.Id, sc.Name }).ToList()
                }).ToList());

            return json.ToString(Formatting.None);
        }

        public static SearchOutput Search(string yaml, IDictionary<string, string> settings, QueryInput q, Session s, IExchange http)
        {
            var g = Build(yaml, settings, s, http);
            var result = Fetch(g.Indexer, ToCriteria(q)).GetAwaiter().GetResult();

            return new SearchOutput(result.Releases, SessionOf(g), g.Status.Changed, g.Outcome.Failed, g.Outcome.FailedStatus);
        }

        private static System.Threading.Tasks.Task<IndexerPageableQueryResult> Fetch(Cardigann indexer, SearchCriteriaBase criteria) =>
            criteria switch
            {
                MovieSearchCriteria m => indexer.Fetch(m),
                TvSearchCriteria t => indexer.Fetch(t),
                BasicSearchCriteria b => indexer.Fetch(b),
                _ => throw new ArgumentException("Unsupported search kind")
            };

        private static SearchCriteriaBase ToCriteria(QueryInput q)
        {
            SearchCriteriaBase criteria;
            switch ((q.Kind ?? "search").ToLowerInvariant())
            {
                case "movie":
                case "movie-search":
                case "movie_search":
                    criteria = new MovieSearchCriteria { SearchType = "movie", ImdbId = q.ImdbId, TmdbId = q.TmdbId };
                    break;
                case "tv":
                case "tvsearch":
                case "tv-search":
                case "tv_search":
                    criteria = new TvSearchCriteria
                    {
                        SearchType = "tvsearch",
                        ImdbId = q.ImdbId,
                        TmdbId = q.TmdbId,
                        TvdbId = q.TvdbId,
                        Season = q.Season,
                        Episode = q.Episode
                    };
                    break;
                default:
                    criteria = new BasicSearchCriteria { SearchType = "search" };
                    break;
            }

            criteria.SearchTerm = q.Term;
            criteria.Categories = q.Categories ?? Array.Empty<int>();
            criteria.Limit = q.Limit;
            criteria.Offset = q.Offset;
            return criteria;
        }

        public static DownloadOutput Download(string yaml, IDictionary<string, string> settings, string link, Session s, IExchange http)
        {
            var g = Build(yaml, settings, s, http);
            var response = g.Indexer.Download(new Uri(link)).GetAwaiter().GetResult();
            var data = response.Data;

            // Upstream turns a magnet link into the bytes of the URL; redirects to
            // a magnet are followed by upstream and end up the same way.
            if (data != null && data.Length > 7 && Encoding.ASCII.GetString(data, 0, 7) == "magnet:")
            {
                return new DownloadOutput(null, Encoding.UTF8.GetString(data), SessionOf(g));
            }

            return new DownloadOutput(data, null, SessionOf(g));
        }

        // Upstream keeps the fetched login page on the cached generator between the
        // captcha probe and DoLogin (GetRequestGenerator hands back the same
        // instance for five minutes). The guest is stateless, so this generator
        // exposes that page and takes it back on the answering call.
        private sealed class LoginGenerator : CardigannRequestGenerator
        {
            public LoginGenerator(CallConfigService config, CardigannDefinition definition, Logger logger, TimeSpan rateLimit)
                : base(config, definition, logger, rateLimit)
            {
            }

            public string LandingHtml => landingResult?.Content;

            public void RestoreLanding(string html)
            {
                landingResultDocument = new AngleSharp.Html.Parser.HtmlParser().ParseDocument(html ?? string.Empty);
            }
        }

        private sealed record CaptchaState(Dictionary<string, string> Cookies, string LandingHtml);

        // Follows the sequence upstream uses in the setup UI: the captcha probe
        // (RequestAction "checkCaptcha" -> GetConfigurationForSetup), then DoLogin
        // with the answer in ExtraFieldData. The answering call restores what the
        // probe captured and goes straight to DoLogin without refetching.
        public static LoginOutput Login(string yaml, IDictionary<string, string> settings, Session s,
                                        string captchaAnswer, string captchaState, IExchange http)
        {
            var settingsWithAnswer = new Dictionary<string, string>(settings ?? new Dictionary<string, string>());
            if (!string.IsNullOrWhiteSpace(captchaAnswer))
            {
                settingsWithAnswer[CaptchaSettingKey] = captchaAnswer;
            }

            var g = Build(yaml, settingsWithAnswer, s, http);
            var definition = g.Defs.GetCachedDefinition(g.Defs.FileKey);

            if (definition.Login == null)
            {
                return new LoginOk(SessionOf(g));
            }

            // Seed the generator cache that Cardigann.GetRequestGenerator reads, so
            // upstream picks up this instance and wires its cookie callbacks.
            var seeded = new LoginGenerator(new CallConfigService(), definition, LogManager.GetLogger("Cardigann"), g.Indexer.RateLimit)
            {
                HttpClient = g.Client
            };
            g.Cache.GetRollingCache<CardigannRequestGenerator>(typeof(Cardigann), "CardigannGeneratorCache", TimeSpan.FromMinutes(5))
                .Set(g.Defs.FileKey, seeded);
            var generator = (LoginGenerator)g.Indexer.GetRequestGenerator();

            var restored = !string.IsNullOrEmpty(captchaState) && !string.IsNullOrWhiteSpace(captchaAnswer);
            if (restored)
            {
                var state = JsonConvert.DeserializeObject<CaptchaState>(captchaState);
                generator.Cookies = state.Cookies;
                generator.RestoreLanding(state.LandingHtml);
            }
            else
            {
                var captcha = generator.GetConfigurationForSetup(false).GetAwaiter().GetResult();

                if (captcha != null)
                {
                    var cookies = generator.Cookies != null
                        ? new Dictionary<string, string>(generator.Cookies)
                        : new Dictionary<string, string>();
                    var state = JsonConvert.SerializeObject(new CaptchaState(cookies, generator.LandingHtml));

                    return new LoginCaptcha(
                        new Session(cookies, g.Status.CookiesExpiration),
                        captcha.ImageData,
                        captcha.ContentType,
                        state);
                }
            }

            generator.DoLogin().GetAwaiter().GetResult();

            return new LoginOk(SessionOf(g));
        }

        public static Session Test(string yaml, IDictionary<string, string> settings, Session s, IExchange http)
        {
            var g = Build(yaml, settings, s, http);
            var result = g.Indexer.Test();

            if (!result.IsValid)
            {
                throw new InvalidOperationException(string.Join("; ", result.Errors.Select(e => e.ErrorMessage)));
            }

            return SessionOf(g);
        }
    }
}
