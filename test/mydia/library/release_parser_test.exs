defmodule Mydia.Library.ReleaseParserTest do
  @moduledoc """
  Facade tests for `Mydia.Library.ReleaseParser`.

  Tests cover the public surface — `parse/1`, `parse/2`,
  `parse_with_path/2` — plus the `:target` and `:standardize` options.
  The 245-case parity gate against the V2 + trash-guide suites lives
  in `release_parser/parity_test.exs`.
  """

  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Library.Structs.Quality

  describe "parse/1 - happy path (unbound)" do
    test "movie release name" do
      result = ReleaseParser.parse("Movie.Name.2020.1080p.BluRay.x264-GROUP.mkv")

      assert %ParsedFileInfo{} = result
      assert result.type == :movie
      assert result.title == "Movie Name"
      assert result.year == 2020
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "BluRay"
      assert result.quality.codec == "x264"
      assert result.release_group == "GROUP"
      assert result.confidence > 0.8
    end

    test "TV show release name" do
      result = ReleaseParser.parse("Show.Name.S01E05.1080p.WEB-DL.mkv")

      assert result.type == :tv_show
      assert result.title == "Show Name"
      assert result.season == 1
      assert result.episodes == [5]
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "WEB-DL"
    end

    test "verbose 'Season N Episode M' release name with trailing punctuation" do
      # Regression for the Off Campus PrimeWire-style filenames: the parser
      # must extract both season and episode (not nil) so MediaImport can
      # match each file to its episode without crashing.
      result =
        ReleaseParser.parse("Off Campus (2026) Season 1 Episode 1- The Deal - PrimeWire.mp4")

      assert result.type == :tv_show
      assert result.title == "Off Campus"
      assert result.year == 2026
      assert result.season == 1
      assert result.episodes == [1]
    end

    test "exposes field_confidence as a non-empty map" do
      result = ReleaseParser.parse("Movie.Name.2020.1080p.BluRay.mkv")

      assert is_map(result.field_confidence)
      assert Map.get(result.field_confidence, :year) != nil
      assert Map.get(result.field_confidence, :resolution) != nil
    end

    test "exposes engine_flags as nil when no signals are raised" do
      result = ReleaseParser.parse("Movie.Name.2020.1080p.BluRay.mkv")
      assert result.engine_flags == nil
    end
  end

  describe "parse/2 - with target binding" do
    test "locks title/type/year and reports binding_confidence" do
      target = %TargetContext{
        type: :tv_show,
        title: "Severance",
        alt_titles: [],
        year: 2022,
        known_seasons: [1, 2]
      }

      result =
        ReleaseParser.parse(
          "Random.Name.S02E04.1080p.mkv",
          target: target
        )

      assert result.type == :tv_show
      assert result.title == "Severance"
      assert result.year == 2022
      assert result.season == 2
      assert result.episodes == [4]

      assert is_map(result.field_confidence)
      assert Map.get(result.field_confidence, :binding) != nil
    end

    test "raises binding_suspect flag when parsed title disagrees" do
      target = %TargetContext{
        type: :tv_show,
        title: "Severance",
        alt_titles: [],
        year: 2022,
        known_seasons: [1, 2]
      }

      result =
        ReleaseParser.parse(
          "Bluey.S02E04.1080p.mkv",
          target: target
        )

      assert result.engine_flags != nil
      assert Map.get(result.engine_flags, :binding_suspect) == true
      assert Map.get(result.engine_flags, :parsed_title_unbound) == "Bluey"
    end

    test "raises season_out_of_range when parsed season isn't in known_seasons" do
      target = %TargetContext{
        type: :tv_show,
        title: "Severance",
        alt_titles: [],
        year: 2022,
        known_seasons: [1]
      }

      result =
        ReleaseParser.parse(
          "Severance.S05E04.1080p.mkv",
          target: target
        )

      assert Map.get(result.engine_flags, :season_out_of_range) == true
    end
  end

  describe "parse/2 - opts[:standardize]" do
    test "false (default) keeps raw token values" do
      result = ReleaseParser.parse("Movie.2020.1080p.BluRay.x264.DDP5.1.mkv")

      assert result.quality.resolution == "1080p"
      assert result.quality.source == "BluRay"
      assert result.quality.codec == "x264"
      assert result.quality.audio == "DDP5.1"
    end

    test "true returns canonical forms matching V2 output" do
      result =
        ReleaseParser.parse(
          "Movie.2020.1080p.BluRay.x264.DDP5.1.mkv",
          standardize: true
        )

      assert result.quality.resolution == "1080p (Full HD)"
      assert result.quality.source == "Blu-ray"
      assert result.quality.codec == "H.264/AVC"
      assert result.quality.audio == "Dolby Digital Plus 5.1"
    end
  end

  describe "parse/2 - edge cases" do
    test "empty filename doesn't crash" do
      result = ReleaseParser.parse("")
      assert %ParsedFileInfo{} = result
      assert result.type == :unknown
      assert result.confidence == 0.0
    end

    test "extension-only filename returns unknown" do
      result = ReleaseParser.parse(".mkv")
      assert result.type == :unknown
    end

    test "full path input still produces a result (basename used)" do
      result = ReleaseParser.parse("/media/movies/Movie Title (2020) 1080p.mkv")
      assert result.title == "Movie Title"
      assert result.year == 2020
    end

    test "empty Quality struct when no quality info" do
      result = ReleaseParser.parse("randomfile.mkv")
      assert %Quality{} = result.quality
      assert Quality.empty?(result.quality)
    end
  end

  describe "parse_with_path/2" do
    test "TV folder structure: folder title takes precedence" do
      result =
        ReleaseParser.parse_with_path("/media/tv/Severance/Season 1/Severance.S01E03.mkv")

      assert result.type == :tv_show
      assert result.title == "Severance"
      assert result.season == 1
      assert result.episodes == [3]
    end

    test "movie folder structure: folder title takes precedence" do
      result =
        ReleaseParser.parse_with_path(
          "/media/movies/Twister (1996) [tmdb-664]/Twister.1996.1080p.mkv"
        )

      assert result.type == :movie
      assert result.title == "Twister"
      assert result.year == 1996
      assert result.external_id == "664"
      assert result.external_provider == :tmdb
    end

    test "falls back to filename when no folder structure" do
      result = ReleaseParser.parse_with_path("/downloads/Movie.Name.2020.1080p.mkv")
      assert result.type == :movie
      assert result.title == "Movie Name"
      assert result.year == 2020
    end
  end

  describe "parse/1 - indexer site-branding prefixes" do
    test "strips a `www.<host> - ` prefix from a TV release" do
      # Regression: a title of this exact shape was returned by a live search.
      # The prefix was folded into the show title as "Www Sitename Org Example
      # Show", whose Jaro distance to the expected title was 0.40, below
      # ReleaseRanker's 0.7 threshold. Every 1080p and 2160p candidate was
      # hard-rejected as a title mismatch and a 360p XviD was grabbed instead.
      # Names are anonymised; the shape is what matters.
      result =
        ReleaseParser.parse(
          "www.SiteName.org    -    Example Show 2024 S02E01 Episode Title 1080p ATVP WEB-DL DDP5 1 Atmos H 264-GRP"
        )

      assert result.type == :tv_show
      assert result.title == "Example Show"
      assert result.year == 2024
      assert result.season == 2
      assert result.episodes == [1]
    end

    test "strips the prefix from the 2160p variant of the same release" do
      result =
        ReleaseParser.parse(
          "www.SiteName.org    -    Example Show 2024 S02E01 Episode Title 2160p ATVP WEB-DL DDP5 1 Atmos DV HDR10Plus H 265-GRP"
        )

      assert result.title == "Example Show"
      assert result.season == 2
      assert result.episodes == [1]
    end

    test "strips a bracketed site prefix" do
      result = ReleaseParser.parse("[ www.Torrenting.org ] Movie.Name.2020.1080p.BluRay.x264-GRP")

      assert result.type == :movie
      assert result.title == "Movie Name"
      assert result.year == 2020
    end

    test "strips a dotted site prefix with no separator" do
      result = ReleaseParser.parse("www.1TamilMV.world - Movie.Name.2020.1080p.BluRay.x264")

      assert result.title == "Movie Name"
      assert result.year == 2020
    end

    test "leaves a title that merely contains www alone" do
      # Only a leading site prefix is stripped. A title is never emptied.
      result = ReleaseParser.parse("Movie.Name.2020.1080p.BluRay.x264-GRP")
      assert result.title == "Movie Name"
    end

    test "does not empty the title when the name is nothing but a site tag" do
      result = ReleaseParser.parse("www.UIndex.org")
      refute result.title == ""
    end

    test "does not eat a title word that follows the host on a dot" do
      # The domain-label run is greedy, so `.The` looked like another label and
      # the space after it satisfied the boundary check, leaving "Matrix".
      # Only an unambiguous boundary (a bracket, a separator glyph, or a bare
      # www.domain.tld before whitespace) may be stripped.
      for title <- [
            "www.example.com.The Sample Film.1999.1080p",
            "www.example.com.The Sample Film 1999 1080p BluRay x264"
          ] do
        result = ReleaseParser.parse(title)

        assert result.title =~ "The Sample",
               "leading article was eaten: #{inspect(result.title)}"

        assert result.year == 1999
      end
    end

    test "leaves a run-on dotted domain alone rather than eating the title" do
      # No delimiter separates the domain from the release, so the labels are
      # indistinguishable from title words. Declining to strip is the safe
      # failure: the title survives intact, just uncleaned.
      result = ReleaseParser.parse("www.Site.org.Movie.Name.2020.1080p.BluRay.x264")

      assert result.title =~ "Movie Name"
      assert result.year == 2020
    end

    test "strips a prefix separated only by whitespace" do
      result = ReleaseParser.parse("www.Torrenting.org Movie.Name.2020.1080p.BluRay.x264")

      assert result.title == "Movie Name"
      assert result.year == 2020
    end
  end
end
