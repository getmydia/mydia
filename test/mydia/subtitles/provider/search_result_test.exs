defmodule Mydia.Subtitles.Provider.SearchResultTest do
  use ExUnit.Case, async: true

  alias Mydia.Subtitles.Provider.SearchResult

  describe "from_map/1" do
    test "a blank origin becomes nil rather than an empty string" do
      result =
        SearchResult.from_map(%{
          "file_id" => 1,
          "language" => "en",
          "format" => "srt",
          "subtitle_hash" => "abc",
          "origin" => ""
        })

      assert result.origin == nil
    end

    test "a present origin is kept" do
      result =
        SearchResult.from_map(%{
          "file_id" => 1,
          "language" => "en",
          "format" => "srt",
          "subtitle_hash" => "abc",
          "origin" => "SubDL"
        })

      assert result.origin == "SubDL"
    end

    test "a whitespace-only origin becomes nil rather than blank whitespace" do
      result =
        SearchResult.from_map(%{
          "file_id" => 1,
          "language" => "en",
          "format" => "srt",
          "subtitle_hash" => "abc",
          "origin" => "   "
        })

      assert result.origin == nil
    end

    test "a padded-but-non-blank origin is trimmed" do
      result =
        SearchResult.from_map(%{
          "file_id" => 1,
          "language" => "en",
          "format" => "srt",
          "subtitle_hash" => "abc",
          "origin" => " SubDL "
        })

      assert result.origin == "SubDL"
    end

    test "a missing origin stays nil" do
      result =
        SearchResult.from_map(%{
          "file_id" => 1,
          "language" => "en",
          "format" => "srt",
          "subtitle_hash" => "abc"
        })

      assert result.origin == nil
    end
  end
end
