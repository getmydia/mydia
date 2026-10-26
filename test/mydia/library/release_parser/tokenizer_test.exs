defmodule Mydia.Library.ReleaseParser.TokenizerTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser.Token
  alias Mydia.Library.ReleaseParser.Tokenizer

  describe "tokenize/1 — basic separators" do
    test "splits on dots, underscores, and spaces" do
      tokens = Tokenizer.tokenize("Show.Name_S01E01 1080p")
      values = Enum.map(tokens, & &1.value)
      assert values == ["Show", "Name", "S01E01", "1080p"]
    end

    test "a double quote separates only past the title boundary" do
      input = ~s(Fake Show "Nick" S01E01 DVDRip."XviD"-GRP)
      tokens = Tokenizer.tokenize(input)

      assert Enum.map(tokens, & &1.value) ==
               ["Fake", "Show", ~s("Nick"), "S01E01", "DVDRip", "XviD", "-GRP"]

      for token <- tokens,
          do: assert(:binary.part(input, token.byte_offset, token.byte_length) == token.value)
    end

    test "drops common extensions" do
      tokens = Tokenizer.tokenize("Movie.2024.mkv")
      assert Enum.map(tokens, & &1.value) == ["Movie", "2024"]

      tokens = Tokenizer.tokenize("Movie.2024.mp4")
      assert Enum.map(tokens, & &1.value) == ["Movie", "2024"]
    end

    test "every token's byte_offset+byte_length slices back to its value via :binary.part" do
      input = "Show.Name.S01E01.1080p.WEB-DL.x264"
      stripped = input
      tokens = Tokenizer.tokenize(input)

      for token <- tokens do
        slice = :binary.part(stripped, token.byte_offset, token.byte_length)
        assert slice == token.value, "Token #{inspect(token)} doesn't round-trip"
      end
    end
  end

  describe "tokenize/1 — bracket context" do
    test "[ ] tokens carry :bracket context" do
      tokens = Tokenizer.tokenize("[Group] Show Name (2024)")
      group = Enum.find(tokens, &(&1.value == "Group"))
      assert group.bracket_context == :bracket

      year = Enum.find(tokens, &(&1.value == "2024"))
      assert year.bracket_context == :paren
    end

    test "tokens outside brackets have nil bracket_context" do
      tokens = Tokenizer.tokenize("Show Name")
      assert Enum.all?(tokens, fn t -> t.bracket_context == nil end)
    end

    test "{ } tokens carry :brace context" do
      tokens = Tokenizer.tokenize("Show {Director's Cut}")
      cut = Enum.find(tokens, &(&1.value == "Cut"))
      assert cut.bracket_context == :brace
    end
  end

  describe "tokenize/1 — embedded dash compounds" do
    test "splits WEB-DL into WEB and DL with correct byte offsets" do
      input = "Show.S01E01.1080p.WEB-DL.x264"
      tokens = Tokenizer.tokenize(input)
      values = Enum.map(tokens, & &1.value)
      assert "WEB" in values
      assert "DL" in values

      web = Enum.find(tokens, &(&1.value == "WEB"))
      dl = Enum.find(tokens, &(&1.value == "DL"))

      assert :binary.part(input, web.byte_offset, web.byte_length) == "WEB"
      assert :binary.part(input, dl.byte_offset, dl.byte_length) == "DL"
    end

    test "non-compound dashes stay un-split" do
      tokens = Tokenizer.tokenize("Spider-Man.2002.1080p.mkv")
      values = Enum.map(tokens, & &1.value)
      assert "Spider-Man" in values
      refute "Spider" in values
      refute "Man" in values
    end

    test "H-264 splits into H and 264" do
      tokens = Tokenizer.tokenize("Show.S01E01.H-264.mkv")
      values = Enum.map(tokens, & &1.value)
      assert "H" in values
      assert "264" in values
    end

    test "DTS-HD splits" do
      tokens = Tokenizer.tokenize("Movie.2024.DTS-HD.MA.5.1.mkv")
      values = Enum.map(tokens, & &1.value)
      assert "DTS" in values
      assert "HD" in values
    end
  end

  describe "tokenize/1 — multibyte UTF-8" do
    test "Japanese filename: byte offsets round-trip via :binary.part" do
      input = "葬送のフリーレン.S02E04.1080p.WEB-DL.x265.mkv"
      stripped = "葬送のフリーレン.S02E04.1080p.WEB-DL.x265"
      tokens = Tokenizer.tokenize(input)

      for token <- tokens do
        slice = :binary.part(stripped, token.byte_offset, token.byte_length)
        assert slice == token.value, "round-trip failed for #{inspect(token)}"
      end

      # The Japanese title token must round-trip exactly
      assert Enum.any?(tokens, &(&1.value == "葬送のフリーレン"))
    end

    test "Korean filename round-trips" do
      input = "오징어게임.S01E01.1080p.mkv"
      stripped = "오징어게임.S01E01.1080p"
      tokens = Tokenizer.tokenize(input)

      for token <- tokens do
        assert :binary.part(stripped, token.byte_offset, token.byte_length) == token.value
      end
    end

    test "Cyrillic filename round-trips" do
      input = "Сериал.S01E01.1080p.mkv"
      stripped = "Сериал.S01E01.1080p"
      tokens = Tokenizer.tokenize(input)

      for token <- tokens do
        assert :binary.part(stripped, token.byte_offset, token.byte_length) == token.value
      end
    end

    test "accented Latin round-trips" do
      input = "Pokémon.Café.2024.1080p.mkv"
      stripped = "Pokémon.Café.2024.1080p"
      tokens = Tokenizer.tokenize(input)

      for token <- tokens do
        assert :binary.part(stripped, token.byte_offset, token.byte_length) == token.value
      end
    end
  end

  describe "anchor_positions/1" do
    test "identifies S01E01 as episode anchor" do
      anchors = Tokenizer.anchor_positions("Show.Name.S01E01.1080p.mkv")
      stripped = "Show.Name.S01E01.1080p"
      assert :binary.part(stripped, anchors.episode_marker, 6) == "S01E01"
    end

    test "identifies 1080p as resolution anchor" do
      anchors = Tokenizer.anchor_positions("Movie.2024.1080p.mkv")
      stripped = "Movie.2024.1080p"
      assert :binary.part(stripped, anchors.resolution, 5) == "1080p"
    end

    test "identifies 2024 as year anchor when no episode marker present" do
      anchors = Tokenizer.anchor_positions("Movie.Title.2024.1080p.mkv")
      stripped = "Movie.Title.2024.1080p"
      assert :binary.part(stripped, anchors.year, 4) == "2024"
    end

    test "title boundary equals min position when resolution beats episode" do
      input = "1080p.Movie.Title.2020.mkv"
      anchors = Tokenizer.anchor_positions(input)
      boundary = Tokenizer.title_boundary(anchors, input)
      assert boundary == 0
    end

    test "year inside TV title is NOT picked up as year anchor (2001 carve-out)" do
      input = "2001 A Space Odyssey S01E01 1080p"
      anchors = Tokenizer.anchor_positions(input)

      assert anchors.year == nil
      refute is_nil(anchors.episode_marker)
    end

    test "year stays as anchor when episode marker is later" do
      input = "Show Name S01E01 2024 1080p"
      anchors = Tokenizer.anchor_positions(input)
      # year position is after the episode marker — but that's not the
      # carve-out case; carve-out only triggers when year < episode.
      refute is_nil(anchors.year)
    end

    test "no anchors → title boundary is full input length (sans extension)" do
      input = "Just Some Title.mkv"
      anchors = Tokenizer.anchor_positions(input)
      assert anchors == %{year: nil, resolution: nil, episode_marker: nil}

      boundary = Tokenizer.title_boundary(anchors, input)
      assert boundary == byte_size("Just Some Title")
    end

    test "1x01 style episode marker" do
      input = "Show Name 1x05 720p"
      anchors = Tokenizer.anchor_positions(input)
      assert :binary.part(input, anchors.episode_marker, 4) == "1x05"
    end

    test "S01 alone (season-only) as episode anchor" do
      input = "Show.Name.S01.1080p"
      anchors = Tokenizer.anchor_positions(input)
      assert :binary.part(input, anchors.episode_marker, 3) == "S01"
    end
  end

  describe "tokenize/1 — edge cases" do
    test "empty input produces no tokens" do
      assert Tokenizer.tokenize("") == []
    end

    test "single token (no separators)" do
      tokens = Tokenizer.tokenize("Movie")
      assert [%Token{value: "Movie", byte_offset: 0, byte_length: 5}] = tokens
    end

    test "leading/trailing separators don't produce empty tokens" do
      tokens = Tokenizer.tokenize("...Show.Name...")
      values = Enum.map(tokens, & &1.value)
      assert values == ["Show", "Name"]
    end

    test "adjacent separators don't produce empty tokens" do
      tokens = Tokenizer.tokenize("Show....Name")
      assert Enum.map(tokens, & &1.value) == ["Show", "Name"]
    end
  end
end
