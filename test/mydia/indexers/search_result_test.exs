defmodule Mydia.Indexers.SearchResultTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.SearchResult

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

      quality = %{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: "DTS",
        hdr: false,
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
      quality = %{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: "DTS",
        hdr: false,
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
      quality = %{
        resolution: "2160p",
        source: "WEB-DL",
        codec: "x265",
        audio: nil,
        hdr: true,
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
      quality = %{
        resolution: "1080p",
        source: "BluRay",
        codec: "x264",
        audio: nil,
        hdr: false,
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
      quality = %{
        resolution: "720p",
        source: nil,
        codec: "x264",
        audio: nil,
        hdr: false,
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
end
