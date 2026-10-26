defmodule Mydia.Library.ReleaseParser.ClassifierTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser.Candidate
  alias Mydia.Library.ReleaseParser.Classifier
  alias Mydia.Library.ReleaseParser.Token
  alias Mydia.Library.ReleaseParser.Tokenizer

  defp classify(input) do
    tokens = Tokenizer.tokenize(input)
    anchors = Tokenizer.anchor_positions(input)
    Classifier.classify(tokens, anchors)
  end

  defp find_token(tokens, value) do
    Enum.find(tokens, fn %Token{value: v} -> v == value end) ||
      flunk("no token with value #{inspect(value)} in #{inspect(Enum.map(tokens, & &1.value))}")
  end

  defp labels(%Token{candidates: cs}), do: Enum.map(cs, & &1.label)

  defp candidate(%Token{candidates: cs}, label) do
    Enum.find(cs, fn %Candidate{label: l} -> l == label end)
  end

  describe "vocabulary-driven candidates" do
    test "x265 token produces a :codec candidate with canonical x265" do
      tokens = classify("Show.S01E01.1080p.x265")
      x265 = find_token(tokens, "x265")
      codec = candidate(x265, :codec)

      assert codec
      assert codec.value == "x265"
      assert codec.confidence >= 0.85
    end

    test "H.265 format aliases map to the same canonical" do
      for input <- ["Show.S01E01.1080p.h265", "Show.S01E01.1080p.HEVC"] do
        tokens = classify(input)
        codec_token = Enum.find(tokens, &candidate(&1, :codec))
        codec = candidate(codec_token, :codec)
        assert codec.value == "H.265", "failed for #{input}"
      end
    end

    test "case-insensitive: bluray and BLURAY classify identically" do
      tokens_lc = classify("Show.S01E01.1080p.bluray")
      tokens_uc = classify("Show.S01E01.1080p.BLURAY")

      lc = candidate(find_token(tokens_lc, "bluray"), :source)
      uc = candidate(find_token(tokens_uc, "BLURAY"), :source)

      assert lc.value == "BluRay"
      assert uc.value == "BluRay"
      assert lc.confidence == uc.confidence
    end
  end

  describe "zone bonuses" do
    test "WEB after a resolution anchor wins as :source (metadata zone)" do
      tokens = classify("Black.Phone.2.2025.1080p.WEB-DL.x265")
      # WEB is split out from WEB-DL by the tokenizer's compound-dash rule.
      web = find_token(tokens, "WEB")
      source = candidate(web, :source)

      assert source.zone == :metadata

      assert source.confidence >= 0.85,
             "WEB in metadata zone should have high source confidence, got #{source.confidence}"
    end

    test "WEB before any anchor (Madame Web case) gets the title-zone penalty" do
      # No anchors at all, so every token is in the title zone.
      tokens = classify("Madame.Web")
      web = find_token(tokens, "Web")
      source = candidate(web, :source)

      assert source.zone == :title

      assert source.confidence <= 0.3,
             "WEB in title zone should be heavily penalized, got #{source.confidence}"
    end

    test "Madame Web with a year still leaves WEB in title zone" do
      # `Web` sits at byte offset 7, before the year anchor at offset 11.
      tokens = classify("Madame.Web.2024.1080p")
      web = find_token(tokens, "Web")
      source = candidate(web, :source)

      assert source.zone == :title
      assert source.confidence <= 0.3
    end
  end

  describe "anchor labels" do
    test "year token gets a :year candidate" do
      tokens = classify("Movie.2024.1080p.x265")
      year = find_token(tokens, "2024")
      assert candidate(year, :year)
    end

    test "resolution token gets a :resolution candidate" do
      tokens = classify("Movie.2024.1080p.x265")
      res = find_token(tokens, "1080p")
      assert candidate(res, :resolution)
    end

    test "S01E01 token gets an :episode_marker candidate" do
      tokens = classify("Show.Name.S01E01.1080p.WEB-DL.x264")
      ep = find_token(tokens, "S01E01")
      assert candidate(ep, :episode_marker)
    end
  end

  describe "title fallback" do
    test "unmatched title-zone tokens get :title_candidate" do
      tokens = classify("Show.Name.S01E01.1080p.WEB-DL.x264")

      show = find_token(tokens, "Show")
      name = find_token(tokens, "Name")

      assert :title_candidate in labels(show)
      assert :title_candidate in labels(name)
    end

    test "title-candidate confidence decays toward the metadata zone" do
      tokens = classify("Show.Name.S01E01.1080p")
      show = find_token(tokens, "Show")
      name = find_token(tokens, "Name")

      show_conf = candidate(show, :title_candidate).confidence
      name_conf = candidate(name, :title_candidate).confidence

      assert show_conf > name_conf,
             "expected earlier title token to score higher: #{show_conf} vs #{name_conf}"
    end

    test "metadata-zone tokens with no vocab match get no candidates" do
      tokens = classify("Show.Name.2024.SomeRandomTag")
      tag = find_token(tokens, "SomeRandomTag")

      assert tag.candidates == []
    end
  end

  describe "Black Phone 2 regression" do
    test "Phone stays a title candidate; WEB resolves as source" do
      tokens = classify("Black.Phone.2.2025.1080p.WEB-DL.x265")

      phone = find_token(tokens, "Phone")
      assert :title_candidate in labels(phone)

      web = find_token(tokens, "WEB")
      web_source = candidate(web, :source)
      assert web_source.zone == :metadata
      assert web_source.confidence >= 0.85
    end
  end

  describe "integration — full classifier pass" do
    test "Show.Name.S01E01.1080p.WEB-DL.x264 produces expected labels" do
      tokens = classify("Show.Name.S01E01.1080p.WEB-DL.x264.mkv")

      assert candidate(find_token(tokens, "S01E01"), :episode_marker)
      assert candidate(find_token(tokens, "1080p"), :resolution)
      web_source = candidate(find_token(tokens, "WEB"), :source)
      assert web_source.confidence >= 0.85
      assert candidate(find_token(tokens, "x264"), :codec).value == "x264"
    end

    test "every emitted candidate has confidence in [0.0, 1.0]" do
      tokens = classify("Show.Name.S01E01.2024.1080p.WEB-DL.HDR.x265-RARBG")

      for token <- tokens, candidate <- token.candidates do
        assert candidate.confidence >= 0.0
        assert candidate.confidence <= 1.0
      end
    end
  end

  describe "extensibility (no algorithm change)" do
    # This test documents the V2-style "add an HDR variant by editing
    # priv/release_parser/hdr.exs" contract: the resolver / classifier
    # don't need to change for new entries to be recognized. We can
    # only verify the *current* set picks up cleanly — the actual file
    # edit is a manual smoke check per the plan.
    test "HDR10 token is recognized via vocabulary" do
      tokens = classify("Movie.2024.2160p.HDR10.x265")
      hdr_token = find_token(tokens, "HDR10")
      hdr = candidate(hdr_token, :hdr)

      assert hdr.value == "HDR10"
      assert hdr.confidence >= 0.8
    end

    test "HDR10+ token preserved as single token and matches vocab" do
      # `+` is not a tokenizer separator, so HDR10+ stays whole.
      tokens = classify("Movie.2024.2160p.HDR10+.x265")
      hdr_token = find_token(tokens, "HDR10+")
      hdr = candidate(hdr_token, :hdr)

      assert hdr.value == "HDR10+"
    end
  end
end
