defmodule MydiaWeb.SearchLive.ResultTypeTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.SearchResult
  alias MydiaWeb.SearchLive.ResultType

  @unparseable "readme"

  defp result(title, category) do
    %SearchResult{
      title: title,
      size: 1,
      seeders: 1,
      leechers: 0,
      download_url: "magnet:?xt=urn:btih:#{:erlang.phash2(title)}",
      indexer: "Test",
      category: category
    }
  end

  describe "detect/1" do
    test "a movie category wins over the title" do
      assert {:movies, :category} =
               ResultType.detect(result("Invented.Show.S01E02.1080p.WEB-DL", 2040))
    end

    test "a TV category is series" do
      assert {:series, :category} = ResultType.detect(result("anything", 5040))
    end

    test "a numeric string category is parsed" do
      assert {:series, :category} = ResultType.detect(result("anything", "5000"))
    end

    test "with no category an episode title is series, guessed from the title" do
      assert {:series, :title} =
               ResultType.detect(result("Invented.Show.S01E02.1080p.WEB-DL.x264-GRP", nil))
    end

    test "with no category a dated release is a movie, guessed from the title" do
      assert {:movies, :title} =
               ResultType.detect(result("Invented.Feature.2021.1080p.BluRay.x264-GRP", nil))
    end

    test "a non-video category falls back to the title" do
      assert {:series, :title} =
               ResultType.detect(result("Invented.Show.S03E04.720p.HDTV.x264-GRP", 3000))
    end

    test "an unparseable title with no category is unknown" do
      assert {:unknown, :none} = ResultType.detect(result(@unparseable, nil))
    end
  end

  describe "media_type/1" do
    test "maps library kinds to media types" do
      assert ResultType.media_type(:movies) == :movie
      assert ResultType.media_type(:series) == :tv_show
      assert ResultType.media_type(:unknown) == nil
    end
  end
end
