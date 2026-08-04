defmodule Mydia.Downloads.TorrentHashTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.TorrentHash

  @hash "58949ffdddcacb400c1aa22fe8253294783bd948"

  describe "ensure_trackers/1" do
    test "appends public trackers to a trackerless magnet" do
      # Shape emitted by Bitmagnet, and by Prowlarr when /download redirects to
      # a magnet instead of serving a .torrent.
      magnet = "magnet:?xt=urn:btih:#{@hash}&dn=Some.Release.1080p"

      enriched = TorrentHash.ensure_trackers(magnet)

      assert String.starts_with?(enriched, magnet)
      assert enriched =~ "&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"
    end

    test "leaves a magnet that already carries trackers untouched" do
      magnet =
        "magnet:?xt=urn:btih:#{@hash}&dn=Some.Release&tr=" <>
          URI.encode("udp://tracker.example.org:1337/announce")

      assert TorrentHash.ensure_trackers(magnet) == magnet
    end

    test "preserves the info hash so client-side dedupe still matches" do
      magnet = "magnet:?xt=urn:btih:#{@hash}&dn=Some.Release"

      enriched = TorrentHash.ensure_trackers(magnet)

      assert TorrentHash.extract({:magnet, enriched}) ==
               TorrentHash.extract({:magnet, magnet})
    end

    test "keeps trailing parameters such as xl intact" do
      magnet = "magnet:?xt=urn:btih:#{@hash}&dn=The.Croods+%282013%29&xl=793286521"

      enriched = TorrentHash.ensure_trackers(magnet)

      assert enriched =~ "&xl=793286521"
      assert enriched =~ "&tr="
    end

    test "does not mistake a dn containing 'tr=' for a tracker parameter" do
      # "attr=value" ends in the literal substring "tr=", so a naive
      # String.contains?(magnet, "tr=") check would decide this magnet already
      # has a tracker and skip enrichment. The parameter is matched per
      # &-separated segment instead, and this segment starts with "dn=".
      magnet = "magnet:?xt=urn:btih:#{@hash}&dn=Release.attr=value"

      assert String.contains?(magnet, "tr=")
      assert TorrentHash.ensure_trackers(magnet) =~ "&tr=udp%3A%2F%2F"
    end

    test "leaves non-magnet input unchanged" do
      url = "https://example.com/file.torrent"

      assert TorrentHash.ensure_trackers(url) == url
    end

    test "leaves nil unchanged" do
      assert TorrentHash.ensure_trackers(nil) == nil
    end

    test "is idempotent" do
      magnet = "magnet:?xt=urn:btih:#{@hash}&dn=Some.Release"

      once = TorrentHash.ensure_trackers(magnet)

      assert TorrentHash.ensure_trackers(once) == once
    end
  end

  describe "build_magnet/2" do
    test "still emits trackers so hash-built magnets keep working" do
      magnet = TorrentHash.build_magnet(@hash, "Some.Release")

      assert magnet =~ "magnet:?xt=urn:btih:#{@hash}"
      assert magnet =~ "&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"
    end

    test "returns nil for an invalid hash" do
      assert TorrentHash.build_magnet("not-a-hash", "Some.Release") == nil
    end
  end
end
