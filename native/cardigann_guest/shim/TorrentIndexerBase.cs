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

        // Upstream calls MonoTorrent's Torrent.Load (3.0.2), which SHA-1 hashes the
        // info dictionary, and System.Security.Cryptography is not supported on
        // wasi-wasm. This performs the checks Torrent.Load makes without the hash,
        // for a v1 torrent (a v2-only torrent is rejected, as Torrent.Load rejects
        // it when v2 support is off):
        //   - the bencode decodes to a dictionary with an `info` dictionary;
        //   - info has an integer `piece length` (int.Parse in Torrent.ProcessInfo);
        //   - info has `pieces`, a byte string whose length is a multiple of 20;
        //   - either `files` (a list of dictionaries; entries with a `path` need an
        //     integer `length`) or an integer `length`;
        //   - the total size is not zero.
        // `name` is not required: Torrent.Load leaves it empty. Not checked: path
        // validity, hybrid v1/v2 consistency and the optional metadata fields.
        protected override void ValidateDownloadData(byte[] fileData)
        {
            try
            {
                var root = BEncodedValue.Decode<BEncodedDictionary>(fileData);
                if (!root.TryGetValue("info", out var infoValue) || infoValue is not BEncodedDictionary info)
                {
                    throw new FormatException("the torrent has no info dictionary");
                }

                if (!info.TryGetValue("piece length", out var pieceLength) || pieceLength is not BEncodedNumber)
                {
                    throw new FormatException("the info dictionary has no integer 'piece length'");
                }

                if (!info.TryGetValue("pieces", out var pieces) || pieces is not BEncodedString pieceHashes)
                {
                    throw new FormatException("the info dictionary has no 'pieces' byte string");
                }

                if (pieceHashes.Span.Length % 20 != 0)
                {
                    throw new FormatException("'pieces' is not a multiple of 20 bytes");
                }

                long size;
                if (info.TryGetValue("files", out var filesValue))
                {
                    if (filesValue is not BEncodedList files)
                    {
                        throw new FormatException("'files' is not a list");
                    }

                    size = 0;
                    foreach (var entry in files)
                    {
                        if (entry is not BEncodedDictionary file)
                        {
                            throw new FormatException("a 'files' entry is not a dictionary");
                        }

                        if (!file.ContainsKey("path") && !file.ContainsKey("path.utf-8"))
                        {
                            continue; // Torrent.Load skips entries without a path
                        }

                        size += FileLength(file);
                    }
                }
                else
                {
                    size = FileLength(info);
                }

                if (size == 0)
                {
                    throw new FormatException("the torrent has no files with a non-zero length");
                }
            }
            catch (Exception ex)
            {
                _logger.Debug("Invalid torrent file contents: {0}", Encoding.ASCII.GetString(fileData));
                throw new NotSupportedException($"Invalid torrent file contents. Reason: {ex.Message}", ex);
            }
        }

        private static long FileLength(BEncodedDictionary dictionary)
        {
            if (!dictionary.TryGetValue("length", out var length) || length is not BEncodedNumber number)
            {
                throw new FormatException("a file has no integer 'length'");
            }

            return number.Number;
        }
    }
}
