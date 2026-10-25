defmodule Mydia.Library.ReleaseParser.VocabularyTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser.Vocabulary
  alias Mydia.Library.ReleaseParser.VocabularyEntry

  describe "all/0" do
    test "loads entries from every vocabulary file" do
      entries = Vocabulary.all()
      labels = entries |> Enum.map(& &1.label) |> Enum.uniq() |> Enum.sort()

      assert :codec in labels
      assert :source in labels
      assert :hdr in labels
      assert :audio in labels
      assert :language in labels
      assert :streaming_service in labels
      assert :release_group in labels
    end

    test "every entry is a %VocabularyEntry{} struct" do
      assert Enum.all?(Vocabulary.all(), &match?(%VocabularyEntry{}, &1))
    end

    test "every entry has at least one alias and a non-empty canonical" do
      for %VocabularyEntry{} = entry <- Vocabulary.all() do
        assert is_list(entry.aliases) and entry.aliases != [],
               "entry #{inspect(entry)} has no aliases"

        assert is_binary(entry.canonical) and entry.canonical != "",
               "entry #{inspect(entry)} has empty canonical"
      end
    end
  end

  describe "lookup/1 — codecs" do
    test "h264 and AVC map to H.264, x264 stays the encoder label" do
      for value <- ["h264", "AVC"] do
        [%VocabularyEntry{} = entry] = Vocabulary.lookup(value)
        assert entry.canonical == "H.264"
        assert entry.label == :codec
      end

      assert [%VocabularyEntry{canonical: "x264", label: :codec}] = Vocabulary.lookup("x264")
    end

    test "h265 and HEVC map to H.265, x265 stays the encoder label" do
      for value <- ["h265", "HEVC"] do
        [%VocabularyEntry{} = entry] = Vocabulary.lookup(value)
        assert entry.canonical == "H.265"
        assert entry.label == :codec
      end

      assert [%VocabularyEntry{canonical: "x265", label: :codec}] = Vocabulary.lookup("x265")
    end
  end

  describe "lookup/1 — case insensitivity" do
    test "BluRay, BLURAY, bluray all match the same source entry" do
      results =
        for value <- ["BluRay", "BLURAY", "bluray", "BlUrAy"] do
          [%VocabularyEntry{} = entry] = Vocabulary.lookup(value)
          entry.canonical
        end

      assert results == ["BluRay", "BluRay", "BluRay", "BluRay"]
    end

    test "x265 / X265 / xHEVC variants all match" do
      assert [%VocabularyEntry{canonical: "x265"}] = Vocabulary.lookup("x265")
      assert [%VocabularyEntry{canonical: "x265"}] = Vocabulary.lookup("X265")
      assert [%VocabularyEntry{canonical: "H.265"}] = Vocabulary.lookup("HEVC")
      assert [%VocabularyEntry{canonical: "H.265"}] = Vocabulary.lookup("hevc")
    end
  end

  describe "lookup/1 — zone bonuses" do
    test "WEB carries a large negative title-zone bonus (Madame Web carve-out)" do
      [%VocabularyEntry{} = entry] = Vocabulary.lookup("WEB")
      assert entry.label == :source
      assert entry.title_zone_bonus <= -0.5
      assert entry.metadata_zone_bonus >= 0.0
    end

    test "MA streaming service carries a strong title-zone penalty" do
      [%VocabularyEntry{} = entry] = Vocabulary.lookup("MA")
      assert entry.label == :streaming_service
      assert entry.title_zone_bonus <= -0.5
    end
  end

  describe "lookup/1 — unknown tokens" do
    test "returns an empty list for an unknown token" do
      assert Vocabulary.lookup("CompletelyMadeUpThing") == []
      assert Vocabulary.lookup("Frieren") == []
    end
  end

  describe "source_files/0" do
    test "registers every priv/release_parser/*.exs as an external resource" do
      files = Vocabulary.source_files()
      basenames = Enum.map(files, &Path.basename/1)

      assert "codecs.exs" in basenames
      assert "sources.exs" in basenames
      assert "hdr.exs" in basenames
      assert "audio.exs" in basenames
      assert "languages.exs" in basenames
      assert "streaming_services.exs" in basenames
      assert "release_groups.exs" in basenames
      assert "revisions.exs" in basenames

      for file <- files do
        assert File.exists?(file), "expected #{file} to exist on disk"
      end
    end
  end
end
