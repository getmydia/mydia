defmodule Mydia.Indexers.SearchResultTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.SearchResult
  alias Mydia.Library.Structs.Quality

  defp search_result(attrs) do
    defaults = %{
      title: "Test.Release.2024.1080p.BluRay.x264-GROUP",
      size: 4_000_000_000,
      seeders: 25,
      leechers: 5,
      download_url: "magnet:?xt=urn:btih:abc123",
      indexer: "Test Indexer"
    }

    struct!(SearchResult, Map.merge(defaults, Map.new(attrs)))
  end

  describe "new/1" do
    test "creates search result with required fields" do
      result =
        SearchResult.new(
          title: "Ubuntu 22.04",
          size: 1_000_000_000,
          seeders: 50,
          leechers: 10,
          download_url: "magnet:?xt=urn:btih:abc123",
          indexer: "Prowlarr"
        )

      assert %SearchResult{
               title: "Ubuntu 22.04",
               size: 1_000_000_000,
               seeders: 50,
               leechers: 10,
               download_url: "magnet:?xt=urn:btih:abc123",
               indexer: "Prowlarr"
             } = result
    end

    test "creates search result with optional fields" do
      published_at = ~U[2024-01-01 00:00:00Z]

      quality = %Quality{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: "DTS",
        proper: false,
        repack: false
      }

      result =
        SearchResult.new(
          title: "Movie.2024.1080p.BluRay.x264",
          size: 4_294_967_296,
          seeders: 100,
          leechers: 50,
          download_url: "magnet:?xt=urn:btih:xyz789",
          indexer: "Prowlarr",
          info_url: "https://example.com/torrent/123",
          category: 2000,
          published_at: published_at,
          quality: quality
        )

      assert %SearchResult{
               info_url: "https://example.com/torrent/123",
               category: 2000,
               published_at: ^published_at,
               quality: ^quality
             } = result
    end

    test "raises when required fields are missing" do
      assert_raise ArgumentError, fn ->
        SearchResult.new(title: "Test")
      end
    end
  end

  describe "health_score/1" do
    test "returns 0.0 when no seeders or leechers" do
      result = %SearchResult{
        title: "Test",
        size: 1000,
        seeders: 0,
        leechers: 0,
        download_url: "magnet:?",
        indexer: "test"
      }

      assert SearchResult.health_score(result) == 0.0
    end

    test "returns low score when no seeders" do
      result = %SearchResult{
        title: "Test",
        size: 1000,
        seeders: 0,
        leechers: 50,
        download_url: "magnet:?",
        indexer: "test"
      }

      assert SearchResult.health_score(result) == 0.1
    end

    test "returns high score for healthy torrents" do
      result = %SearchResult{
        title: "Test",
        size: 1000,
        seeders: 100,
        leechers: 50,
        download_url: "magnet:?",
        indexer: "test"
      }

      score = SearchResult.health_score(result)
      assert score > 0.5
      assert score <= 1.0
    end

    test "caps score at 1.0" do
      result = %SearchResult{
        title: "Test",
        size: 1000,
        seeders: 1000,
        leechers: 1,
        download_url: "magnet:?",
        indexer: "test"
      }

      assert SearchResult.health_score(result) == 1.0
    end
  end

  describe "format_size/1" do
    test "formats bytes" do
      result = %SearchResult{
        title: "Test",
        size: 500,
        seeders: 1,
        leechers: 1,
        download_url: "magnet:?",
        indexer: "test"
      }

      assert SearchResult.format_size(result) == "500 B"
    end

    test "formats kilobytes" do
      result = %SearchResult{
        title: "Test",
        size: 1024 * 5,
        seeders: 1,
        leechers: 1,
        download_url: "magnet:?",
        indexer: "test"
      }

      assert SearchResult.format_size(result) == "5.0 KB"
    end

    test "formats megabytes" do
      result = %SearchResult{
        title: "Test",
        size: 1024 * 1024 * 100,
        seeders: 1,
        leechers: 1,
        download_url: "magnet:?",
        indexer: "test"
      }

      assert SearchResult.format_size(result) == "100.0 MB"
    end

    test "formats gigabytes" do
      result = %SearchResult{
        title: "Test",
        size: 1024 * 1024 * 1024 * 4,
        seeders: 1,
        leechers: 1,
        download_url: "magnet:?",
        indexer: "test"
      }

      assert SearchResult.format_size(result) == "4.0 GB"
    end

    test "rounds to one decimal place" do
      result = %SearchResult{
        title: "Test",
        size: 1_536_000_000,
        seeders: 1,
        leechers: 1,
        download_url: "magnet:?",
        indexer: "test"
      }

      assert SearchResult.format_size(result) == "1.4 GB"
    end
  end

  describe "quality_description/1" do
    test "returns 'Unknown' when quality is nil" do
      result = %SearchResult{
        title: "Test",
        size: 1000,
        seeders: 1,
        leechers: 1,
        download_url: "magnet:?",
        indexer: "test",
        quality: nil
      }

      assert SearchResult.quality_description(result) == "Unknown"
    end

    test "formats quality with all fields" do
      quality = %Quality{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: "DTS",
        proper: false,
        repack: false
      }

      result = %SearchResult{
        title: "Test",
        size: 1000,
        seeders: 1,
        leechers: 1,
        download_url: "magnet:?",
        indexer: "test",
        quality: quality
      }

      assert SearchResult.quality_description(result) == "1080p BluRay x264 DTS"
    end

    test "formats quality with HDR" do
      quality = %Quality{
        resolution: "2160p",
        source: "WEB-DL",
        codec: "x265",
        audio: nil,
        hdr_format: :hdr10,
        proper: false,
        repack: false
      }

      result = %SearchResult{
        title: "Test",
        size: 1000,
        seeders: 1,
        leechers: 1,
        download_url: "magnet:?",
        indexer: "test",
        quality: quality
      }

      assert SearchResult.quality_description(result) == "2160p WEB-DL x265 HDR"
    end

    test "formats quality with PROPER and REPACK" do
      quality = %Quality{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: nil,
        proper: true,
        repack: true
      }

      result = %SearchResult{
        title: "Test",
        size: 1000,
        seeders: 1,
        leechers: 1,
        download_url: "magnet:?",
        indexer: "test",
        quality: quality
      }

      assert SearchResult.quality_description(result) == "1080p BluRay x264 PROPER REPACK"
    end

    test "omits nil fields from description" do
      quality = %Quality{
        resolution: "720p",
        source: nil,
        codec: "x264",
        audio: nil,
        proper: false,
        repack: false
      }

      result = %SearchResult{
        title: "Test",
        size: 1000,
        seeders: 1,
        leechers: 1,
        download_url: "magnet:?",
        indexer: "test",
        quality: quality
      }

      assert SearchResult.quality_description(result) == "720p x264"
    end
  end

  describe "info_page_url/1" do
    test "returns an https URL unchanged" do
      result = search_result(info_url: "https://tracker.example/details/42")

      assert SearchResult.info_page_url(result) == "https://tracker.example/details/42"
    end

    test "returns an http URL unchanged" do
      result = search_result(info_url: "http://tracker.example/details/42")

      assert SearchResult.info_page_url(result) == "http://tracker.example/details/42"
    end

    test "trims surrounding whitespace" do
      result = search_result(info_url: "  https://tracker.example/details/42\n")

      assert SearchResult.info_page_url(result) == "https://tracker.example/details/42"
    end

    test "rejects a javascript: URL" do
      result = search_result(info_url: "javascript:alert(1)")

      assert SearchResult.info_page_url(result) == nil
    end

    test "rejects a data: URL" do
      result = search_result(info_url: "data:text/html,<script>alert(1)</script>")

      assert SearchResult.info_page_url(result) == nil
    end

    test "rejects a protocol-relative URL" do
      result = search_result(info_url: "//evil.example/details/42")

      assert SearchResult.info_page_url(result) == nil
    end

    test "rejects a relative path" do
      result = search_result(info_url: "/details/42")

      assert SearchResult.info_page_url(result) == nil
    end

    test "rejects a magnet link" do
      result = search_result(info_url: "magnet:?xt=urn:btih:def456")

      assert SearchResult.info_page_url(result) == nil
    end

    test "rejects an http URL with no host" do
      result = search_result(info_url: "http://")

      assert SearchResult.info_page_url(result) == nil
    end

    test "returns nil when info_url is nil" do
      result = search_result(info_url: nil)

      assert SearchResult.info_page_url(result) == nil
    end

    test "returns nil for an empty or whitespace-only info_url" do
      assert SearchResult.info_page_url(search_result(info_url: "")) == nil
      assert SearchResult.info_page_url(search_result(info_url: "   ")) == nil
    end

    test "returns nil when info_url is identical to download_url" do
      result =
        search_result(
          download_url: "https://tracker.example/download/42.torrent",
          info_url: "https://tracker.example/download/42.torrent"
        )

      assert SearchResult.info_page_url(result) == nil
    end

    test "still resolves for a struct carrying the stream_position key" do
      streamed =
        search_result(info_url: "https://tracker.example/details/42")
        |> Map.put(:stream_position, 3)

      assert SearchResult.info_page_url(streamed) == "https://tracker.example/details/42"
    end
  end
end
