[
  %{
    definition: "bigfangroup",
    query: :movie,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's download.php link"
  },
  %{
    definition: "bigfangroup",
    query: :movie,
    kind: :field,
    field: :title,
    reason:
      "the row has three a[href^=\"details.php?id=\"] links (title, seeders 1, leechers 3); native joins all their text (title + \"13\"), wasm takes the first match"
  },
  %{
    definition: "bigfangroup",
    query: :movie,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "bigfangroup",
    query: :rss,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's download.php link"
  },
  %{
    definition: "bigfangroup",
    query: :rss,
    kind: :field,
    field: :title,
    reason:
      "the row has three a[href^=\"details.php?id=\"] links (title, seeders 2, leechers 4); native joins all their text (title + \"24\"), wasm takes the first match"
  },
  %{
    definition: "bigfangroup",
    query: :rss,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "blueroms",
    query: :rss,
    kind: :field,
    field: :category,
    reason:
      "native CategoryMapping maps PC and Console categories to 8000 (Other) on purpose; wasm maps this row's Console/NDS (/switch) to 1010"
  },
  %{
    definition: "blueroms",
    query: :rss,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's download link"
  },
  %{
    definition: "blueroms",
    query: :rss,
    kind: :field,
    field: :published_at,
    reason:
      "`date: text: now` has no date filter; native parse_date(\"now\") is nil, wasm resolves now to the replay time"
  },
  %{
    definition: "blueroms",
    query: :rss,
    kind: :field,
    field: :title,
    reason:
      "the append filter's \" - {{ .Result.title_platform }}\" renders in native without the row's fields in scope, so the platform is empty; wasm appends \" - Nintendo Switch\""
  },
  %{
    definition: "blueroms",
    query: :rss,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "dmhy",
    query: :movie,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's magnet link"
  },
  %{
    definition: "dmhy",
    query: :movie,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "dmhy",
    query: :rss,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's magnet link"
  },
  %{
    definition: "dmhy",
    query: :rss,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "linuxtracker",
    query: :generic,
    kind: :field,
    field: :category,
    reason:
      "the definition maps by `categorydesc`, which native does not implement (nil); wasm maps the badge to 4020 (PC/ISO)"
  },
  %{
    definition: "linuxtracker",
    query: :generic,
    kind: :field,
    field: :download_url,
    reason:
      "both build a magnet from infohash; native TorrentHash.build_magnet uses a lowercase hash and Mydia's 8 trackers, wasm an uppercase hash and Prowlarr's 20"
  },
  %{
    definition: "linuxtracker",
    query: :generic,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's magnet link"
  },
  %{
    definition: "linuxtracker",
    query: :generic,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "linuxtracker",
    query: :rss,
    kind: :count,
    field: nil,
    reason:
      "wasm leaves out the two rows whose category badge (AnduinOS) has no categorymappings entry; native keeps them with category nil (25 vs 23)"
  },
  %{
    definition: "linuxtracker",
    query: :rss,
    kind: :field,
    field: :category,
    reason:
      "the definition maps by `categorydesc`, which native does not implement (nil); wasm maps the badge to 4020 (PC/ISO)"
  },
  %{
    definition: "linuxtracker",
    query: :rss,
    kind: :field,
    field: :download_url,
    reason:
      "both build a magnet from infohash; native TorrentHash.build_magnet uses a lowercase hash and Mydia's 8 trackers, wasm an uppercase hash and Prowlarr's 20"
  },
  %{
    definition: "linuxtracker",
    query: :rss,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's magnet link"
  },
  %{
    definition: "linuxtracker",
    query: :rss,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "mikan",
    query: :rss,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's .torrent download link"
  },
  %{
    definition: "mikan",
    query: :rss,
    kind: :field,
    field: :published_at,
    reason:
      "date_year_raw's regexp uses \\u00A0, which PCRE2 rejects, so native skips the filter and keeps the size cell (\"360.3 MB\"); date_year becomes \"360.3 MB +08:00\", dateparse leaves it unparsed, `or` prefers it over date_day and parse_date gives nil. wasm drops the non-matching cell and uses date_day (\"今天 02:30\" as today). Native is nil whatever the clock, so the divergence does not depend on when the test runs"
  },
  %{
    definition: "mikan",
    query: :rss,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "mikan",
    query: :tv,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's .torrent download link"
  },
  %{
    definition: "mikan",
    query: :tv,
    kind: :field,
    field: :size,
    reason:
      "native reads the \"1,017.6 MB\" size cell as 17.6 MiB (18454937), losing the thousands group; wasm reads 1017.6 MiB (1067030937)"
  },
  %{
    definition: "mikan",
    query: :tv,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "nekobt",
    query: :movie,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's magnet link"
  },
  %{
    definition: "nekobt",
    query: :movie,
    kind: :field,
    field: :published_at,
    reason:
      "pubDate ends in \"+0000\" and the GMT replace does not fire; native dateparse \"zzz\" only accepts \"+00:00\" (nil), wasm parses \"+0000\""
  },
  %{
    definition: "nekobt",
    query: :movie,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "nekobt",
    query: :rss,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's magnet link"
  },
  %{
    definition: "nekobt",
    query: :rss,
    kind: :field,
    field: :published_at,
    reason:
      "pubDate ends in \"+0000\" and the GMT replace does not fire; native dateparse \"zzz\" only accepts \"+00:00\" (nil), wasm parses \"+0000\""
  },
  %{
    definition: "nekobt",
    query: :rss,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "nyaasi",
    query: :movie,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's magnet link"
  },
  %{
    definition: "nyaasi",
    query: :movie,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "nyaasi",
    query: :rss,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's magnet link"
  },
  %{
    definition: "nyaasi",
    query: :rss,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "pctorrent",
    query: :rss,
    kind: :field,
    field: :category,
    reason:
      "`category: text: 1` is a YAML integer; native drops the field (nil), wasm maps site category 1 to 4050 (PC/Games)"
  },
  %{
    definition: "pctorrent",
    query: :rss,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's details page URL"
  },
  %{
    definition: "pctorrent",
    query: :rss,
    kind: :field,
    field: :published_at,
    reason:
      "`date: text: now` has no date filter; native parse_date(\"now\") is nil, wasm resolves now to the replay time"
  },
  %{
    definition: "pctorrent",
    query: :rss,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  },
  %{
    definition: "yts",
    query: :rss,
    kind: :field,
    field: :download_url,
    reason:
      "native prefers the infohash field and builds a magnet; wasm keeps the yts.gg torrent download URL"
  },
  %{
    definition: "yts",
    query: :rss,
    kind: :field,
    field: :guid,
    reason:
      "native never sets SearchResult.guid; wasm fills Prowlarr's guid with the release's torrent download URL"
  },
  %{
    definition: "yts",
    query: :rss,
    kind: :field,
    field: :info_url,
    reason:
      "native has no .Config.sitelink, so the details re_replace leaves movies/<slug>, which resolves against the API search URL; wasm substitutes https://yts.gg/"
  },
  %{
    definition: "yts",
    query: :rss,
    kind: :field,
    field: :published_at,
    reason:
      "date is date_uploaded_unix with no filter; native parse_date only takes ISO 8601 (nil), wasm reads the Unix timestamp"
  },
  %{
    definition: "yts",
    query: :rss,
    kind: :field,
    field: :tmdb_id,
    reason:
      "no tmdbid field: native parse_integer(nil) turns the missing value into 0, wasm leaves nil"
  }
]
