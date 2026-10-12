using System;
using System.Text;
using MonoTorrent.BEncoding;
using NLog;
using NzbDrone.Core.Configuration;
using NzbDrone.Core.Messaging.Events;

namespace NzbDrone.Core.Indexers
{
    public abstract class TorrentIndexerBase<TSettings> : HttpIndexerBase<TSettings>
        where TSettings : IIndexerSettings, new()
    {
        public override DownloadProtocol Protocol => DownloadProtocol.Torrent;

        protected TorrentIndexerBase(IIndexerHttpClient httpClient, IEventAggregator eventAggregator, IIndexerStatusService indexerStatusService, IConfigService configService, Logger logger)
            : base(httpClient, eventAggregator, indexerStatusService, configService, logger)
        {
        }

        // Upstream calls MonoTorrent's Torrent.Load, which hashes the info
        // dictionary with SHA1, and System.Security.Cryptography is not supported
        // on wasi-wasm. Decoding the bencode and requiring an "info" dictionary
        // rejects what Torrent.Load rejects in practice: HTML error pages, empty
        // bodies and truncated files.
        protected override void ValidateDownloadData(byte[] fileData)
        {
            try
            {
                var root = BEncodedValue.Decode<BEncodedDictionary>(fileData);
                if (!root.ContainsKey("info") || root["info"] is not BEncodedDictionary)
                {
                    throw new FormatException("the torrent has no info dictionary");
                }
            }
            catch (Exception ex)
            {
                _logger.Debug("Invalid torrent file contents: {0}", Encoding.ASCII.GetString(fileData));
                throw new NotSupportedException($"Invalid torrent file contents. Reason: {ex.Message}", ex);
            }
        }
    }
}
