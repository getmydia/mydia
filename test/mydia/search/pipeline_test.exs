defmodule Mydia.Search.PipelineTest do
  use Mydia.DataCase, async: true

  alias Mydia.Search.Pipeline
  alias Mydia.Media.MediaItem

  describe "build_search_query/1" do
    test "returns title and year for movies with year" do
      media_item = %MediaItem{title: "The Matrix", year: 1999}
      assert Pipeline.build_search_query(media_item) == "The Matrix 1999"
    end

    test "returns just title when year is nil" do
      media_item = %MediaItem{title: "Untitled Film"}
      assert Pipeline.build_search_query(media_item) == "Untitled Film"
    end
  end

  describe "get_min_seeders/0" do
    test "returns configured value or default 0" do
      result = Pipeline.get_min_seeders()
      assert is_integer(result)
      assert result >= 0
    end
  end

  describe "stringify_keys/1" do
    test "converts atom keys to string keys" do
      result = Pipeline.stringify_keys(%{quality: "1080p", score: 85.0})
      assert result == %{"quality" => "1080p", "score" => 85.0}
    end

    test "handles struct maps by converting from struct first" do
      result = Pipeline.stringify_keys(%URI{host: "example.com", port: 443})
      assert is_map(result)
      assert Map.has_key?(result, "host")
    end

    test "passes through non-map values" do
      assert Pipeline.stringify_keys("hello") == "hello"
      assert Pipeline.stringify_keys(42) == 42
    end
  end

  describe "build_filter_stats/2" do
    test "builds stats with correct counts" do
      results = [
        %{seeders: 1, title: "low"},
        %{seeders: 100, title: "high"},
        %{seeders: 0, title: "zero"}
      ]

      stats = Pipeline.build_filter_stats(results, min_seeders: 5)
      assert stats["total_results"] == 3
      assert stats["low_seeders"] == 2
      assert stats["below_quality_threshold"] == 1
    end
  end
end
