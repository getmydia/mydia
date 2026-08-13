defmodule Mydia.Downloads.TorrentHashTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.TorrentHash

  @hash "58949ffdddcacb400c1aa22fe8253294783bd948"

  # Kept in sync with @public_trackers in Mydia.Downloads.TorrentHash. Pinned
  # here on purpose: the enriched bytes are asserted exactly, so a silent change
  # to the list shows up as a test failure rather than as a shipped surprise.
  @trackers [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://tracker.dler.org:6969/announce",
    "udp://tracker.qu.ax:6969/announce",
    "udp://open.demonoid.ch:6969/announce"
  ]

  # A minimal but structurally complete `info` dictionary, keys in bencode
  # (lexicographic) order: files < name < piece length < pieces.
  @info "d5:filesld6:lengthi835673131e4:pathl8:test.mkveee" <>
          "4:name8:test.mkv12:piece lengthi16384e6:pieces0:e"

  # Byte-for-byte the shape Prowlarr served for the 1337x grab that stalled at 0
  # bytes in production: a go.torrent-generated metainfo with no `announce` and
  # no `announce-list` anywhere in the top-level dict.
  @trackerless "d7:comment28:dynamic metainfo from client" <>
                 "10:created by10:go.torrent13:creation datei1786573608e" <>
                 "4:info" <> @info <> "e"

  defp bencode_string(value), do: "#{byte_size(value)}:#{value}"

  defp announce_prefix do
    tiers = Enum.map_join(@trackers, fn tracker -> "l" <> bencode_string(tracker) <> "e" end)

    "8:announce" <>
      bencode_string(hd(@trackers)) <>
      "13:announce-listl" <> tiers <> "e"
  end

  defp body_after_open_dict(<<?d, rest::binary>>), do: rest

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

  describe "ensure_torrent_trackers/1" do
    test "splices every public tracker into a trackerless .torrent file" do
      enriched = TorrentHash.ensure_torrent_trackers(@trackerless)

      for tracker <- @trackers do
        assert String.contains?(enriched, tracker),
               "expected #{tracker} in the enriched metainfo"
      end

      assert enriched == "d" <> announce_prefix() <> body_after_open_dict(@trackerless)
    end

    test "announce-list is a list of single-tracker tiers, per BEP-12" do
      enriched = TorrentHash.ensure_torrent_trackers(@trackerless)

      tiers = Enum.map_join(@trackers, fn tracker -> "l" <> bencode_string(tracker) <> "e" end)

      assert String.contains?(enriched, "13:announce-listl" <> tiers <> "e")
    end

    test "leaves the info hash byte-identical" do
      {:ok, before} = TorrentHash.extract_from_file(@trackerless)

      {:ok, after_hash} =
        TorrentHash.extract_from_file(TorrentHash.ensure_torrent_trackers(@trackerless))

      assert before == after_hash
    end

    test "keeps the result a parseable metainfo file" do
      enriched = TorrentHash.ensure_torrent_trackers(@trackerless)

      assert TorrentHash.valid_metainfo?(enriched)
      assert {:ok, _hash} = TorrentHash.extract_from_file(enriched)
    end

    test "leaves a torrent that already announces a tracker untouched" do
      tracked =
        "d8:announce34:udp://tracker.example.org:1337/ann7:comment4:test" <>
          "4:info" <> @info <> "e"

      assert TorrentHash.ensure_torrent_trackers(tracked) == tracked
    end

    test "leaves a torrent with announce-list but no announce untouched" do
      # BEP-12 says announce-list supersedes announce, and some generators emit
      # only the list. Such a torrent already has peers to ask.
      listed =
        "d13:announce-listll34:udp://tracker.example.org:1337/annee7:comment4:test" <>
          "4:info" <> @info <> "e"

      assert TorrentHash.ensure_torrent_trackers(listed) == listed
    end

    test "is idempotent" do
      once = TorrentHash.ensure_torrent_trackers(@trackerless)

      assert TorrentHash.ensure_torrent_trackers(once) == once
    end

    test "leaves non-bencode input unchanged" do
      # NZB payloads reach the same call site and must survive it untouched.
      nzb = ~s(<?xml version="1.0"?><nzb><file subject="x" /></nzb>)

      assert TorrentHash.ensure_torrent_trackers(nzb) == nzb
    end

    test "leaves a truncated bencode dict unchanged instead of crashing" do
      truncated = "d7:comment28:dynamic metainfo from cli"

      assert TorrentHash.ensure_torrent_trackers(truncated) == truncated
    end

    test "leaves garbage that merely starts with 'd' unchanged" do
      garbage = "dnot-bencode-at-all"

      assert TorrentHash.ensure_torrent_trackers(garbage) == garbage
    end

    test "leaves empty and nil input unchanged" do
      assert TorrentHash.ensure_torrent_trackers("") == ""
      assert TorrentHash.ensure_torrent_trackers(nil) == nil
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
