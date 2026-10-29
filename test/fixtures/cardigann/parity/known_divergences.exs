[
  %{
    definition: "blueroms",
    query: :rss,
    kind: :field,
    field: :category,
    reason:
      "native CategoryMapping maps PC and Console categories to 8000 (Other) on purpose; wasm maps this row's Console/NDS (/switch) to 1010"
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
      "both set guid from the magnet the infohash builds; native TorrentHash.build_magnet uses a lowercase hash and Mydia's 8 trackers, wasm an uppercase hash and Prowlarr's 20"
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
      "both set guid from the magnet the infohash builds; native TorrentHash.build_magnet uses a lowercase hash and Mydia's 8 trackers, wasm an uppercase hash and Prowlarr's 20"
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
    definition: "pctorrent",
    query: :rss,
    kind: :field,
    field: :category,
    reason:
      "`category: text: 1` extracts \"1\" in native, whose CategoryMapping maps PC/Games to 8000 (Other) on purpose; wasm maps site category 1 to 4050 (PC/Games)"
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
      "both set guid from the download field; native has no .Config.sitelink, so the definition's re_replace strips the yts domain and LinkResolver resolves the rest against the API search URL; wasm substitutes https://yts.gg/"
  },
  %{
    definition: "yts",
    query: :rss,
    kind: :field,
    field: :info_url,
    reason:
      "native has no .Config.sitelink, so the details re_replace leaves movies/<slug>, which resolves against the API search URL; wasm substitutes https://yts.gg/"
  }
]
