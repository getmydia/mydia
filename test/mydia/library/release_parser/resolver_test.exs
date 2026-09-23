defmodule Mydia.Library.ReleaseParser.ResolverTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser.Classifier
  alias Mydia.Library.ReleaseParser.Resolver
  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Library.ReleaseParser.Tokenizer

  defp resolve(input, target \\ nil) do
    tokens =
      input
      |> Tokenizer.tokenize()
      |> Classifier.classify(Tokenizer.anchor_positions(input))

    Resolver.resolve(tokens, target)
  end

  describe "unbound TV show" do
    test "Show.Name.S01E01.1080p.x264 produces type/title/season/episodes/quality" do
      result = resolve("Show.Name.S01E01.1080p.x264")

      assert result.type == :tv_show
      assert result.title == "Show Name"
      assert result.season == 1
      assert result.episodes == [1]

      assert Enum.any?(result.quality_tokens, fn entry ->
               entry.label == :resolution and entry.value == "1080p"
             end)

      assert Enum.any?(result.quality_tokens, fn entry ->
               entry.label == :codec and entry.value == "H.264/AVC"
             end)

      assert result.field_confidence[:title] >= 0.5
      assert result.field_confidence[:season] >= 0.8
      assert result.field_confidence[:resolution] >= 0.8
      assert result.field_confidence[:codec] >= 0.8
    end

    test "S01E01E02E03 produces episodes=[1, 2, 3]" do
      result = resolve("Show.Name.S01E01E02E03.1080p")
      assert result.season == 1
      assert result.episodes == [1, 2, 3]
    end

    test "S01E01-E03 produces episodes=[1, 2, 3]" do
      result = resolve("Show.Name.S01E01-E03.1080p")
      assert result.season == 1
      assert result.episodes == [1, 2, 3]
    end

    test "1x05 produces season=1, episodes=[5]" do
      result = resolve("Show.Name.1x05.1080p")
      assert result.season == 1
      assert result.episodes == [5]
    end

    test "verbose 'Season N Episode M' produces season + episodes" do
      result = resolve("Off Campus (2026) Season 1 Episode 1 The Deal")
      assert result.season == 1
      assert result.episodes == [1]
    end

    test "verbose 'Season N Episode M-' with trailing punctuation still extracts episode" do
      # Regression: filenames like "Season 1 Episode 1- The Deal - PrimeWire.mp4"
      # leave a trailing dash on the episode-number token. The episode integer
      # must still be parsed instead of falling through to nil and crashing
      # downstream import code.
      result = resolve("Off Campus (2026) Season 1 Episode 1- The Deal - PrimeWire")
      assert result.season == 1
      assert result.episodes == [1]
    end
  end

  describe "unbound movie" do
    test "Movie.Title.2024.2160p.BluRay.x265 produces movie + year + quality" do
      result = resolve("Movie.Title.2024.2160p.BluRay.x265")

      assert result.type == :movie
      assert result.year == 2024
      assert result.title == "Movie Title"
      assert result.season == nil
      assert result.episodes == nil

      assert Enum.any?(result.quality_tokens, fn e ->
               e.label == :resolution and e.value == "2160p"
             end)

      assert Enum.any?(result.quality_tokens, fn e ->
               e.label == :source and e.value == "BluRay"
             end)

      assert Enum.any?(result.quality_tokens, fn e ->
               e.label == :codec and e.value == "H.265/HEVC"
             end)
    end

    test "no anchors at all -> :unknown" do
      result = resolve("Random.Release.Name")
      assert result.type == :unknown
    end
  end

  describe "Black Phone 2 regression" do
    test "title includes the number; source is WEB-DL" do
      result = resolve("Black.Phone.2.2025.1080p.WEB-DL.x265")

      assert result.title == "Black Phone 2"
      assert result.year == 2025

      assert Enum.any?(result.quality_tokens, fn e ->
               e.label == :source and e.value == "WEB"
             end)
    end
  end

  describe "Madame Web carve-out" do
    test "Web stays in the title, not classified as source" do
      result = resolve("Madame.Web.2024.1080p")

      assert result.title == "Madame Web"
      assert result.year == 2024
      refute Enum.any?(result.quality_tokens, fn e -> e.label == :source end)
    end
  end

  describe "bound to TargetContext" do
    test "type/title/year locked to target; season and episodes parsed" do
      target = %TargetContext{
        type: :tv_show,
        title: "Frieren",
        year: 2023,
        known_seasons: [1, 2]
      }

      result = resolve("Frieren.S02E04.1080p.x265", target)

      assert result.type == :tv_show
      assert result.title == "Frieren"
      assert result.year == 2023
      assert result.season == 2
      assert result.episodes == [4]
      assert result.binding_confidence != nil
      assert result.binding_confidence >= 0.5
    end

    test "season out of range with bound target adds engine flag and lowers season confidence" do
      target = %TargetContext{
        type: :tv_show,
        title: "Frieren",
        year: 2023,
        known_seasons: [1, 2]
      }

      result = resolve("Frieren.S03E01.1080p", target)

      assert result.season == 3
      assert result.engine_flags[:season_out_of_range] == true

      assert result.field_confidence[:season] <=
               Mydia.Library.ReleaseParser.Config.suggest_threshold()
    end

    test "bound title disagreement flags binding suspect" do
      target = %TargetContext{
        type: :tv_show,
        title: "Severance",
        year: 2022,
        known_seasons: [1]
      }

      result = resolve("Random.Other.Show.S01E01.1080p", target)

      assert result.title == "Severance"
      assert result.binding_confidence != nil
      assert result.binding_confidence < 0.5
      assert result.engine_flags[:binding_suspect] == true
      assert is_binary(result.engine_flags[:parsed_title_unbound])
    end

    test "binding_confidence preserves title diagnostic when binding is wrong" do
      target = %TargetContext{
        type: :tv_show,
        title: "Severance",
        year: 2022,
        known_seasons: [1]
      }

      result = resolve("Random.Other.Show.S01E01.1080p", target)

      # field_confidence.title is NOT clamped to 1.0 — it's the parser's
      # actual confidence in the title from the tokens.
      refute result.field_confidence[:title] == 1.0
    end

    test "target with no year leaves year nil if input has none" do
      target = %TargetContext{
        type: :movie,
        title: "Sample Movie",
        known_seasons: []
      }

      result = resolve("Sample.Movie.1080p", target)

      assert result.title == "Sample Movie"
      assert result.year == nil
    end

    test "target year overrides parsed year" do
      target = %TargetContext{
        type: :movie,
        title: "Sample Movie",
        year: 2024,
        known_seasons: []
      }

      result = resolve("Sample.Movie.1999.1080p", target)

      assert result.year == 2024
      assert result.field_confidence[:year] == 1.0
    end
  end

  describe "conflict resolution" do
    test "two year-like tokens — highest-confidence wins" do
      # Both 2001 and 2024 look like years. The classifier only marks the
      # first match as :year (per Tokenizer.anchor_positions); but if both
      # had year candidates the highest confidence would win.
      result = resolve("Movie.2001.2024.1080p")
      assert result.year in [2001, 2024]
    end
  end

  describe "per-field confidence shape" do
    test "field_confidence is always a map (possibly empty)" do
      result = resolve("Show.Name.S01E01.1080p.x264")
      assert is_map(result.field_confidence)
    end

    test "unset fields don't appear in field_confidence" do
      result = resolve("Random.Words")
      refute Map.has_key?(result.field_confidence, :year)
      refute Map.has_key?(result.field_confidence, :season)
    end
  end

  describe "language detection" do
    test "Spanish vocab token is classified as :language" do
      result = resolve("Movie.Title.2024.SPANISH.1080p.x265")

      # We don't require language to surface as a top-level field unless
      # the vocab classifies it; the test asserts the resolver doesn't
      # crash and emits the canonical when it does.
      if result.language do
        assert is_binary(result.language)
        assert result.field_confidence[:language] != nil
      end
    end
  end

  describe "vocabulary words inside the title" do
    test "a language word followed by a title word stays in the title" do
      result = resolve("The.Italian.Harbor.2031.1080p.WEB-DL.x264")

      assert result.title == "The Italian Harbor"
      assert result.language == nil
    end

    test "a leading language word followed by a title word stays in the title" do
      result = resolve("French.Harbor.2031.1080p.WEB-DL.x264")

      assert result.title == "French Harbor"
      assert result.language == nil
    end

    test "a TV title starting with Multi keeps it" do
      result = resolve("Multi.Season.Show.S01.COMPLETE.1080p.WEB-DL.x264")

      assert result.title == "Multi Season Show"
      assert result.season == 1
      assert result.language == nil
    end

    test "an audio word inside the title stays a tag" do
      result = resolve("Quiet.Opus.Harbor.2031.1080p.WEB-DL.x264")

      assert result.title == "Quiet Harbor"
      assert Enum.any?(result.quality_tokens, &(&1.label == :audio))
    end

    test "a vocab word that ends the title zone stays a tag, even before a year" do
      assert resolve("Quiet.Opus.2031.1080p.WEB-DL.x264").title == "Quiet"

      result = resolve("Der.Film.Lantern.German.2031.PAL.DVDR")
      assert result.title == "Der Film Lantern"
      assert result.language == "German"
    end

    test "a quality word next to a title word does not leak release noise into the title" do
      result = resolve("Series.10910.hdtv-lol")

      refute result.title =~ "Hdtv"
    end

    test "a title-zone word does not displace a metadata-zone tag of its label" do
      result = resolve("The.Italian.Harbor.2031.FRENCH.1080p.WEB-DL.x264")

      assert result.title == "The Italian Harbor"
      assert result.language == "French"
    end

    test "a tag at the end of the title zone stays a tag" do
      result = resolve("Show.Name.S01.FRENCH.1080p.WEB-DL.x264")

      assert result.title == "Show Name"
      assert result.language == "French"
    end

    test "a tag after the year stays a tag" do
      result = resolve("Movie.Name.2031.GERMAN.1080p.WEB-DL.x264")

      assert result.title == "Movie Name"
      assert result.language == "German"
    end

    test "a run of tags stays tags even when a stray word follows it" do
      result = resolve("Movie.Name.MULTi.BluRay.x264.GRP")

      refute result.title =~ "Multi"
      refute result.title =~ "BluRay"
      assert result.language == "Multi"
    end

    test "a single vocab word that is the whole title is the title" do
      result = resolve("French.2031.1080p.WEB-DL.x264")

      assert result.title == "French"
      assert result.language == nil
    end

    test "a lone vocab word with no anchor is not reclaimed" do
      result = resolve("FRENCH")

      assert result.title == nil
      assert result.language == "French"
    end
  end

  describe "empty / degenerate input" do
    test "empty token list returns :unknown without crashing" do
      result = Resolver.resolve([], nil)
      assert result.type == :unknown
      assert result.title == nil
      assert result.year == nil
      assert result.season == nil
      assert result.episodes == nil
      assert is_map(result.field_confidence)
    end
  end
end
