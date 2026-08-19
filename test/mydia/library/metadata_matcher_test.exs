defmodule Mydia.Library.MetadataMatcherTest do
  @moduledoc """
  Query normalisation, the one part of this module that is both public and pure.

  Candidate selection used to live here too, as `test_*` re-implementations of
  the private scoring functions. Those moved to
  `metadata_matcher_scoring_test.exs`, where they drive the real code through
  `match_tv_show/3` and `match_movie/3` instead of a copy of it.
  """
  use ExUnit.Case, async: true

  alias Mydia.Library.MetadataMatcher

  describe "normalize_search_query/1" do
    test "removes year suffix with separator and everything after" do
      assert MetadataMatcher.normalize_search_query("The.Simpsons.1989-(71663)") == "The Simpsons"

      assert MetadataMatcher.normalize_search_query("Breaking.Bad.2008-something") ==
               "Breaking Bad"

      assert MetadataMatcher.normalize_search_query("Movie_Name_2020_extra_stuff") == "Movie Name"
    end

    test "removes year in parentheses and everything after" do
      assert MetadataMatcher.normalize_search_query("The+Simpsons+(1989)+{imdb-tt0096697}") ==
               "The Simpsons"

      assert MetadataMatcher.normalize_search_query("Inception (2010) 1080p") == "Inception"
    end

    test "removes IMDB ID annotations" do
      assert MetadataMatcher.normalize_search_query("The+Simpsons+{imdb-tt0096697}") ==
               "The Simpsons"

      assert MetadataMatcher.normalize_search_query("Movie.Name{IMDB-tt1234567}") == "Movie Name"
    end

    test "removes TVDB ID annotations" do
      assert MetadataMatcher.normalize_search_query("The.Simpsons[tvdbid-71663]") ==
               "The Simpsons"

      assert MetadataMatcher.normalize_search_query("Show[TVDBID-12345]") == "Show"
    end

    test "removes TMDB ID annotations" do
      assert MetadataMatcher.normalize_search_query("Movie.Name{tmdb-123}") == "Movie Name"
      assert MetadataMatcher.normalize_search_query("Show[tmdbid-456]") == "Show"
    end

    test "removes quality indicators and everything after" do
      assert MetadataMatcher.normalize_search_query("Movie.Name.2020.1080p.BluRay.x264-RARBG") ==
               "Movie Name"

      assert MetadataMatcher.normalize_search_query("Show.S01E01.720p.HDTV") == "Show S01E01"
      assert MetadataMatcher.normalize_search_query("Film.2160p.4K.UHD") == "Film"
      assert MetadataMatcher.normalize_search_query("Movie.480p") == "Movie"
    end

    test "removes source format indicators and everything after" do
      assert MetadataMatcher.normalize_search_query("Movie.BluRay.1080p") == "Movie"
      assert MetadataMatcher.normalize_search_query("Show.WEBRip.x264") == "Show"
      assert MetadataMatcher.normalize_search_query("Film.Web-DL.AAC") == "Film"
      assert MetadataMatcher.normalize_search_query("Movie.HDTV.x265") == "Movie"
      assert MetadataMatcher.normalize_search_query("Film.DVDRip.XviD") == "Film"
    end

    test "removes codec indicators and everything after" do
      assert MetadataMatcher.normalize_search_query("Movie.Name.x264-GROUP") == "Movie Name"
      assert MetadataMatcher.normalize_search_query("Film.h265.10bit") == "Film"
      assert MetadataMatcher.normalize_search_query("Show.HEVC.AAC") == "Show"
      assert MetadataMatcher.normalize_search_query("Movie.XviD.MP3") == "Movie"
    end

    test "removes release group tags at end" do
      assert MetadataMatcher.normalize_search_query("Movie.Name-RARBG") == "Movie Name"
      assert MetadataMatcher.normalize_search_query("Film-YTS") == "Film"
      assert MetadataMatcher.normalize_search_query("Show-YIFY") == "Show"
    end

    test "replaces separators with spaces" do
      assert MetadataMatcher.normalize_search_query("The.Matrix") == "The Matrix"
      assert MetadataMatcher.normalize_search_query("Star_Wars") == "Star Wars"
      assert MetadataMatcher.normalize_search_query("Fast+Furious") == "Fast Furious"
      assert MetadataMatcher.normalize_search_query("The-Office") == "The Office"
    end

    test "collapses multiple spaces" do
      assert MetadataMatcher.normalize_search_query("Movie   Name") == "Movie Name"
      assert MetadataMatcher.normalize_search_query("The  Matrix") == "The Matrix"
    end

    test "trims whitespace" do
      assert MetadataMatcher.normalize_search_query("  Movie Name  ") == "Movie Name"
      assert MetadataMatcher.normalize_search_query("   The Matrix   ") == "The Matrix"
    end

    test "handles complex real-world examples" do
      # Example from task description
      assert MetadataMatcher.normalize_search_query("The.Simpsons.1989-(71663)") ==
               "The Simpsons"

      assert MetadataMatcher.normalize_search_query("The+Simpsons+(1989)+{imdb-tt0096697}") ==
               "The Simpsons"

      # Complex movie filename
      assert MetadataMatcher.normalize_search_query(
               "Inception.2010.1080p.BluRay.x264.DTS-HD.MA.5.1-RARBG"
             ) == "Inception"

      # TV show filename
      assert MetadataMatcher.normalize_search_query(
               "Breaking.Bad.S01E01.1080p.BluRay.x264-ROVERS"
             ) == "Breaking Bad S01E01"

      # Movie with year at end
      assert MetadataMatcher.normalize_search_query("The.Matrix.1999") == "The Matrix"
    end

    test "handles standalone year at end with separator" do
      assert MetadataMatcher.normalize_search_query("The.Matrix.1999") == "The Matrix"
      assert MetadataMatcher.normalize_search_query("Inception-2010") == "Inception"
      assert MetadataMatcher.normalize_search_query("Movie_Name_2020") == "Movie Name"
    end

    test "preserves episode information" do
      # Episode markers should not be removed
      assert MetadataMatcher.normalize_search_query("Show.S01E01.1080p") == "Show S01E01"

      assert MetadataMatcher.normalize_search_query("Series.S02E05.720p.HDTV") ==
               "Series S02E05"
    end

    test "handles empty and nil inputs gracefully" do
      assert MetadataMatcher.normalize_search_query("") == ""
      assert MetadataMatcher.normalize_search_query(nil) == nil
    end

    test "handles inputs without metadata" do
      # Clean titles should pass through unchanged (except separators)
      assert MetadataMatcher.normalize_search_query("The Matrix") == "The Matrix"
      assert MetadataMatcher.normalize_search_query("Inception") == "Inception"
    end

    test "handles mixed case quality indicators" do
      assert MetadataMatcher.normalize_search_query("Movie.1080P.BLURAY") == "Movie"
      assert MetadataMatcher.normalize_search_query("Film.X264.AAC") == "Film"
    end
  end
end
