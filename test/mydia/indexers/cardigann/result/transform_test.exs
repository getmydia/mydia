defmodule Mydia.Indexers.Cardigann.Result.TransformTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Result.{Context, Transform}
  alias Mydia.Indexers.SearchResult

  @category_mappings [%{"id" => 7, "cat" => "Movies/HD"}]

  defp ctx(overrides \\ %{}) do
    struct!(
      %Context{
        indexer_name: "Lantern",
        base_url: "https://lantern.invalid",
        category_mappings: @category_mappings
      },
      overrides
    )
  end

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => "Lantern Harbor 1080p",
        "download" => "/download/1.torrent",
        "size" => "1.5 GB",
        "seeders" => "12",
        "leechers" => "3",
        "details" => "/details/1",
        "category" => "7",
        "date" => "2026-10-01T12:30:00Z",
        "tmdbid" => "42",
        "imdbid" => "tt0000042"
      },
      overrides
    )
  end

  defp one(row, ctx \\ ctx()) do
    assert [result] = Transform.search_results([row], ctx)
    result
  end

  describe "search_results/2" do
    test "builds a result from a complete row" do
      result = one(row())

      assert %SearchResult{} = result
      assert result.title == "Lantern Harbor 1080p"
      assert result.size == 1_610_612_736
      assert result.seeders == 12
      assert result.leechers == 3
      assert result.download_url == "https://lantern.invalid/download/1.torrent"
      assert result.info_url == "https://lantern.invalid/details/1"
      assert result.indexer == "Lantern"
      assert result.category == 2040
      assert result.published_at == ~U[2026-10-01 12:30:00Z]
      assert result.tmdb_id == 42
      assert result.imdb_id == "tt0000042"
      assert result.download_protocol == :torrent
    end

    test "drops a row without a title or a download" do
      untitled = row(%{"title" => ""})
      undownloadable = row(%{"download" => ""})

      assert [result] = Transform.search_results([untitled, undownloadable, row()], ctx())
      assert result.title == "Lantern Harbor 1080p"
    end

    test "leaves a missing or blank tmdbid nil" do
      assert one(row(%{"tmdbid" => nil})).tmdb_id == nil
      assert one(row(%{"tmdbid" => ""})).tmdb_id == nil
    end

    test "leaves absent optional fields empty and counts at zero" do
      result =
        one(
          row(%{
            "size" => nil,
            "seeders" => nil,
            "leechers" => nil,
            "details" => nil,
            "category" => nil,
            "date" => nil,
            "tmdbid" => nil,
            "imdbid" => nil
          })
        )

      assert result.size == 0
      assert result.seeders == 0
      assert result.leechers == 0
      assert result.info_url == nil
      assert result.category == nil
      assert result.published_at == nil
      assert result.imdb_id == nil
    end

    test "prefers a magnet built from the infohash" do
      result = one(row(%{"infohash" => String.duplicate("a", 40)}))

      assert result.download_url =~ "magnet:?xt=urn:btih:" <> String.duplicate("a", 40)
      assert result.download_protocol == :torrent
    end

    test "falls back to the download field when the infohash cannot build a magnet" do
      result = one(row(%{"infohash" => "not-a-hash"}))

      assert result.download_url == "https://lantern.invalid/download/1.torrent"
    end

    test "sets the guid to the resolved download link" do
      assert one(row()).guid == "https://lantern.invalid/download/1.torrent"
    end

    test "keeps the download link as guid when the infohash supplies the download URL" do
      result = one(row(%{"infohash" => String.duplicate("b", 40)}))

      assert result.download_url =~ "magnet:?xt=urn:btih:" <> String.duplicate("b", 40)
      assert result.guid == "https://lantern.invalid/download/1.torrent"
    end

    test "sets the guid to the magnet built from the infohash when there is no download link" do
      result = one(row(%{"download" => nil, "infohash" => String.duplicate("c", 40)}))

      assert result.guid == result.download_url
    end

    test "detects an NZB download URL" do
      result = one(row(%{"download" => "/download/1.nzb"}))

      assert result.download_protocol == :nzb
    end

    test "keeps a numeric category that has no mapping" do
      assert one(row(%{"category" => "4050"})).category == 4050
    end

    test "leaves the category empty when the row has none" do
      assert one(row(%{"category" => ""})).category == nil
    end
  end

  describe "parse_size/1" do
    test "parses TB, GB, MB and KB as binary units" do
      assert Transform.parse_size("1.5 TB") == 1_649_267_441_664
      assert Transform.parse_size("1.5 GB") == 1_610_612_736
      assert Transform.parse_size("500 MB") == 524_288_000
      assert Transform.parse_size("1024 KB") == 1_048_576
      assert Transform.parse_size("2 GiB") == 2_147_483_648
    end

    test "treats a unitless number as bytes" do
      assert Transform.parse_size("1024") == 1024
    end

    test "returns zero for nil, blank and unparseable values" do
      assert Transform.parse_size(nil) == 0
      assert Transform.parse_size("") == 0
      assert Transform.parse_size("invalid") == 0
      assert Transform.parse_size("N/A") == 0
    end
  end

  describe "parse_size_with_title_fallback/2" do
    test "uses the size field when it parses" do
      assert Transform.parse_size_with_title_fallback("1.5 GB", "Lantern Harbor (2.5Gb)") ==
               1_610_612_736
    end

    test "falls back to a size embedded in the title" do
      assert Transform.parse_size_with_title_fallback("", "Lantern Harbor (2.5Gb)") ==
               2_684_354_560
    end

    test "returns zero when neither source carries a size" do
      assert Transform.parse_size_with_title_fallback("", "Lantern Harbor") == 0
      assert Transform.parse_size_with_title_fallback(nil, nil) == 0
    end
  end

  describe "parse_date/1" do
    test "parses ISO 8601 with and without an offset" do
      assert Transform.parse_date("2026-10-01T12:30:00Z") == ~U[2026-10-01 12:30:00Z]
      assert Transform.parse_date("2026-10-01T12:30:00+02:00") == ~U[2026-10-01 10:30:00Z]
    end

    test "returns nil for nil, blank and unparseable values" do
      assert Transform.parse_date(nil) == nil
      assert Transform.parse_date("") == nil
      assert Transform.parse_date("not a date") == nil
    end
  end
end
