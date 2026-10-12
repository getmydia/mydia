#if WASM_BUILD
using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using Mydia.CardigannGuest;
using Mydia.CardigannGuest.Shim;
using NLog;
using NzbDrone.Common.Http;
using NzbDrone.Core.Exceptions;
using NzbDrone.Core.Http.CloudFlare;
using NzbDrone.Core.Indexers.Definitions.Cardigann.Exceptions;
using NzbDrone.Core.Indexers.Exceptions;
using NzbDrone.Core.Parser.Model;
using T = CardigannWorld.wit.Imports.mydia.cardigann.v1_0_0.ITypesImports;

namespace CardigannWorld.wit.Exports.mydia.cardigann.v1_0_0
{
    // The generated export wrappers call these static members by name.
    public class EngineExportsImpl : IEngineExports
    {
        private static readonly IExchange Exchange = new HostExchange();

        static EngineExportsImpl()
        {
            LogManager.Setup().LoadConfiguration(c =>
                c.ForLogger().FilterMinLevel(LogLevel.Debug).WriteTo(new HostLogTarget()));
        }

        public static string Capabilities(string defYaml) =>
            Guard(() => Runner.Capabilities(defYaml));

        public static T.SearchOut Search(string defYaml, List<T.Setting> settings, T.Query q, T.Session s) =>
            Guard(() =>
            {
                var output = Runner.Search(defYaml, ToSettings(settings), ToInput(q), ToSession(s), Exchange);
                return new T.SearchOut(
                    output.Releases.Select(ToRelease).ToList(),
                    FromSession(output.Session),
                    output.SessionChanged,
                    output.RequestFailed);
            });

        public static T.DownloadOut Download(string defYaml, List<T.Setting> settings, string link, T.Session s) =>
            Guard(() =>
            {
                var output = Runner.Download(defYaml, ToSettings(settings), link, ToSession(s), Exchange);
                var payload = output.Bytes != null
                    ? T.DownloadPayload.Bytes(output.Bytes)
                    : T.DownloadPayload.Link(output.MagnetOrUrl);
                return new T.DownloadOut(payload, FromSession(output.Session));
            });

        public static T.LoginOut Login(string defYaml, List<T.Setting> settings, T.Session s, T.CaptchaAnswer? answer) =>
            Guard(() =>
            {
                var output = Runner.Login(defYaml, ToSettings(settings), ToSession(s),
                    answer?.answer, answer?.state, Exchange);
                return output switch
                {
                    LoginCaptcha c => T.LoginOut.Captcha(new T.CaptchaChallenge(c.Image, c.ContentType, c.State)),
                    _ => T.LoginOut.Ok(FromSession(output.Session))
                };
            });

        public static T.Session Test(string defYaml, List<T.Setting> settings, T.Session s) =>
            Guard(() => FromSession(Runner.Test(defYaml, ToSettings(settings), ToSession(s), Exchange)));

        // ---- conversions ----

        private static Dictionary<string, string> ToSettings(List<T.Setting> settings)
        {
            var map = new Dictionary<string, string>();
            foreach (var setting in settings)
            {
                map[setting.name] = setting.value;
            }

            return map;
        }

        private static Session ToSession(T.Session s)
        {
            var cookies = new Dictionary<string, string>();
            foreach (var cookie in s.cookies)
            {
                cookies[cookie.name] = cookie.value;
            }

            DateTime? expires = s.expiresUnix.HasValue
                ? DateTimeOffset.FromUnixTimeSeconds(s.expiresUnix.Value).UtcDateTime
                : null;
            return new Session(cookies, expires);
        }

        private static T.Session FromSession(Session s)
        {
            var cookies = (s?.Cookies ?? new Dictionary<string, string>())
                .Select(kv => new T.Header(kv.Key, kv.Value))
                .ToList();
            long? expires = s?.Expires is DateTime d
                ? new DateTimeOffset(DateTime.SpecifyKind(d, d.Kind == DateTimeKind.Unspecified ? DateTimeKind.Utc : d.Kind)).ToUnixTimeSeconds()
                : null;
            return new T.Session(cookies, expires);
        }

        private static QueryInput ToInput(T.Query q)
        {
            var kind = q.kind switch
            {
                T.QueryKind.MOVIE => "movie",
                T.QueryKind.TV => "tv",
                _ => "search"
            };
            return new QueryInput(kind, q.term, q.categories, q.imdbId, q.tmdbId, q.tvdbId, q.season,
                q.episode, q.limit, q.offset);
        }

        private static int? NonZero(int id) => id > 0 ? id : null;

        private static string ImdbString(int id) => id > 0 ? "tt" + id.ToString("D7") : null;

        private static T.Release ToRelease(ReleaseInfo r)
        {
            var torrent = r as TorrentInfo;
            return new T.Release(
                r.Title ?? string.Empty,
                r.Guid ?? string.Empty,
                r.DownloadUrl,
                torrent?.MagnetUrl,
                r.InfoUrl,
                torrent?.InfoHash,
                r.Size,
                torrent?.Seeders,
                torrent?.Peers,
                r.Grabs,
                r.PublishDate == default
                    ? null
                    : new DateTimeOffset(r.PublishDate.ToUniversalTime()).ToUnixTimeSeconds(),
                r.Categories.Select(c => c.Id).ToArray(),
                ImdbString(r.ImdbId),
                NonZero(r.TmdbId),
                NonZero(r.TvdbId),
                torrent?.DownloadVolumeFactor,
                torrent?.UploadVolumeFactor,
                torrent?.MinimumRatio,
                torrent?.MinimumSeedTime);
        }

        // ---- error mapping ----

        private static TResult Guard<TResult>(Func<TResult> body)
        {
            try
            {
                return body();
            }
            catch (WitException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new WitException(Map(ex), 0);
            }
        }

        // Unexpected failures often wrap the real cause (YamlDotNet, reflection
        // under AOT), so an internal error carries the whole chain.
        private static string InnerChain(Exception ex)
        {
            var text = "";
            for (var inner = ex.InnerException; inner != null; inner = inner.InnerException)
            {
                text += "\ncaused by " + inner.GetType().FullName + ": " + inner.Message;
            }

            return text;
        }

        private static T.EngineError Map(Exception ex)
        {
            var message = ex.Message;
            return ex switch
            {
                CardigannConfigException => T.EngineError.LoginFailed(message),
                IndexerAuthException => T.EngineError.LoginFailed(message),
                TooManyRequestsException => T.EngineError.RequestLimit(message),
                RequestLimitReachedException => T.EngineError.RequestLimit(message),
                CloudFlareProtectionException => T.EngineError.Cloudflare(message),
                CardigannException => T.EngineError.ParseFailed(message),
                IndexerException => T.EngineError.ParseFailed(message),
                // A failed download wraps what went wrong: an HTTP status or an
                // HTML page where a torrent was expected is the site's answer,
                // anything else (a body that is not a torrent) is unreadable data.
                ReleaseDownloadException { InnerException: HttpException inner } =>
                    T.EngineError.Http(message + ": " + inner.Message),
                ReleaseDownloadException =>
                    T.EngineError.ParseFailed(message + (ex.InnerException != null ? ": " + ex.InnerException.Message : "")),
                NotSupportedException when message.StartsWith("Invalid torrent file contents", StringComparison.Ordinal) =>
                    T.EngineError.ParseFailed(message),
                HttpRequestException => T.EngineError.Http(message),
                HttpException => T.EngineError.Http(message),
                WebException => T.EngineError.Http(message),
                _ => T.EngineError.@internal(ex.GetType().FullName + ": " + message + "\n" + ex.StackTrace + InnerChain(ex))
            };
        }
    }
}
#endif
