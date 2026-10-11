using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Text;
using Mydia.CardigannGuest.Shim;
using Newtonsoft.Json;
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

    public sealed record SearchOutput(IList<ReleaseInfo> Releases, Session Session, bool SessionChanged);

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

        private sealed class Graph
        {
            public Cardigann Indexer;
            public CallIndexerStatusService Status;
            public SingleDefinitionService Defs;
            public CacheManager Cache;
        }

        private sealed class ThrowingExchange : IExchange
        {
            public RawResponse Send(RawRequest request) =>
                throw new InvalidOperationException("No HTTP is available for this call");
        }

        private sealed record CaptchaState(Dictionary<string, string> Cookies);

        private static Graph Build(string yaml, IDictionary<string, string> settings, Session session, IExchange http)
        {
            var defs = new SingleDefinitionService(yaml);
            var logger = LogManager.GetLogger("Cardigann");
            var cache = new CacheManager();
            var status = new CallIndexerStatusService(
                new Dictionary<string, string>(session?.Cookies ?? new Dictionary<string, string>()),
                session?.Expires);
            var client = new IndexerHttpClient(
                new NoProxyFactory(),
                Array.Empty<IHttpRequestInterceptor>(),
                cache,
                new NoRateLimitService(),
                new ExchangeDispatcher(http),
                logger);

            var indexer = new Cardigann(defs, client, new NullEventAggregator(), status, new CallConfigService(), cache, logger);

            // The same definition upstream builds for its indexer list, with the
            // user's settings in ExtraFieldData as the settings binding stores them.
            var definition = indexer.DefaultDefinitions.Cast<IndexerDefinition>().First();
            definition.Id = 1;
            var extra = ((CardigannSettings)definition.Settings).ExtraFieldData;
            foreach (var (key, value) in settings ?? new Dictionary<string, string>())
            {
                extra[key] = value;
            }

            indexer.Definition = definition;

            return new Graph { Indexer = indexer, Status = status, Defs = defs, Cache = cache };
        }

        private static Session SessionOf(Graph g) => new Session(g.Status.Cookies, g.Status.CookiesExpiration);

        public static string Capabilities(string yaml)
        {
            var g = Build(yaml, null, null, new ThrowingExchange());
            return JsonConvert.SerializeObject(g.Indexer.GetCapabilities());
        }

        public static SearchOutput Search(string yaml, IDictionary<string, string> settings, QueryInput q, Session s, IExchange http)
        {
            var g = Build(yaml, settings, s, http);
            var result = Fetch(g.Indexer, ToCriteria(q)).GetAwaiter().GetResult();

            return new SearchOutput(result.Releases, SessionOf(g), g.Status.Changed);
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

        // Follows the sequence upstream uses on the first search of a private
        // definition and in the setup UI: the captcha probe (RequestAction
        // "checkCaptcha" -> GetConfigurationForSetup), then DoLogin.
        public static LoginOutput Login(string yaml, IDictionary<string, string> settings, Session s,
                                        string captchaAnswer, string captchaState, IExchange http)
        {
            var settingsWithAnswer = new Dictionary<string, string>(settings ?? new Dictionary<string, string>());
            if (!string.IsNullOrWhiteSpace(captchaAnswer))
            {
                settingsWithAnswer[CaptchaSettingKey] = captchaAnswer;
            }

            var g = Build(yaml, settingsWithAnswer, s, http);
            var generator = (CardigannRequestGenerator)g.Indexer.GetRequestGenerator();
            var definition = g.Defs.GetCachedDefinition(g.Defs.FileKey);

            if (definition.Login == null)
            {
                return new LoginOk(SessionOf(g));
            }

            // The captcha is tied to the cookies of the page that showed it, so a
            // second call restores them where HttpClient keeps its persistent jar.
            if (!string.IsNullOrEmpty(captchaState))
            {
                var state = JsonConvert.DeserializeObject<CaptchaState>(captchaState);
                RestoreCaptchaCookies(g, definition, state);
            }

            var captcha = generator.GetConfigurationForSetup(false).GetAwaiter().GetResult();

            if (captcha != null && string.IsNullOrWhiteSpace(captchaAnswer))
            {
                var cookies = generator.Cookies != null
                    ? new Dictionary<string, string>(generator.Cookies)
                    : new Dictionary<string, string>();
                var state = JsonConvert.SerializeObject(new CaptchaState(cookies));

                return new LoginCaptcha(
                    new Session(cookies, g.Status.CookiesExpiration),
                    captcha.ImageData,
                    captcha.ContentType,
                    state);
            }

            generator.DoLogin().GetAwaiter().GetResult();

            return new LoginOk(SessionOf(g));
        }

        private static void RestoreCaptchaCookies(Graph g, CardigannDefinition definition, CaptchaState state)
        {
            if (state?.Cookies == null || definition.Links == null || definition.Links.Count == 0)
            {
                return;
            }

            var uri = new Uri(definition.Links[0]);
            var jar = g.Cache.GetCache<CookieContainer>(typeof(NzbDrone.Common.Http.HttpClient))
                .Get("container", () => new CookieContainer());

            foreach (var (name, value) in state.Cookies)
            {
                jar.Add(uri, new Cookie(name, value, "/"));
            }
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
