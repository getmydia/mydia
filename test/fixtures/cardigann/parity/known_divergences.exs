[
  %{
    definition: "linuxtracker",
    query: :rss,
    kind: :count,
    field: nil,
    reason:
      "wasm leaves out the two rows whose category badge (AnduinOS) has no categorymappings entry; native keeps them with category nil (25 vs 23)"
  },
  %{
    definition: "yts",
    query: :rss,
    kind: :field,
    field: :download_url,
    reason:
      "native prefers the infohash field and builds a magnet; wasm keeps the yts.gg torrent download URL"
  }
]
