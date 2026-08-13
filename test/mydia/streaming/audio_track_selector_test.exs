defmodule Mydia.Streaming.AudioTrackSelectorTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Streaming.AudioTrackSelector

  # ffprobe numbers every elementary stream in one sequence, so a file's first
  # audio track is rarely index 0. These fixtures keep that offset because the
  # `-map` argument the selector feeds ffmpeg is an absolute container index,
  # and a helper that quietly renumbered from zero would let an off-by-one
  # through the whole suite.
  defp audio(index, language, opts \\ []) do
    %StreamInfo{
      index: index,
      type: :audio,
      codec: Keyword.get(opts, :codec, "aac"),
      language: language,
      title: Keyword.get(opts, :title),
      channels: Keyword.get(opts, :channels, 2),
      is_default: Keyword.get(opts, :is_default, false),
      is_forced: false,
      is_commentary: Keyword.get(opts, :is_commentary, false)
    }
  end

  defp video(index \\ 0) do
    %StreamInfo{index: index, type: :video, codec: "h264", width: 1920, height: 1080}
  end

  describe "select/3 with a language preference" do
    test "picks English over a Russian track the container flags default" do
      # The reported bug, in its exact shape: a release that muxes the Russian
      # dub first and flags it default, with the English original second.
      streams = [
        video(),
        audio(1, "rus", is_default: true, channels: 6),
        audio(2, "eng")
      ]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["en"])
      assert track.index == 2
      assert track.language == "eng"
    end

    test "honours preference order, not container order" do
      streams = [video(), audio(1, "eng"), audio(2, "jpn")]

      assert {:ok, japanese} = AudioTrackSelector.select(streams, ["ja", "en"])
      assert japanese.language == "jpn"

      assert {:ok, english} = AudioTrackSelector.select(streams, ["en", "ja"])
      assert english.language == "eng"
    end

    test "falls through to the next preference when the first is absent" do
      streams = [video(), audio(1, "rus", is_default: true), audio(2, "eng")]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["de", "fr", "en"])
      assert track.language == "eng"
    end

    test "matches a two-letter preference against ffprobe's three-letter tag" do
      streams = [video(), audio(1, "rus", is_default: true), audio(2, "eng")]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["en"])
      assert track.language == "eng"
    end

    test "matches ISO 639-2/B codes, which is what Matroska actually carries" do
      # Matroska writes the bibliographic variant: "ger" not "deu", "fre" not
      # "fra". A table with only the terminological form silently never
      # matches a German or French track.
      streams = [video(), audio(1, "eng", is_default: true), audio(2, "ger"), audio(3, "fre")]

      assert {:ok, german} = AudioTrackSelector.select(streams, ["de"])
      assert german.language == "ger"

      assert {:ok, french} = AudioTrackSelector.select(streams, ["fr"])
      assert french.language == "fre"
    end

    test "matches a region-suffixed preference against a bare tag" do
      streams = [video(), audio(1, "rus", is_default: true), audio(2, "por")]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["pt-BR"])
      assert track.language == "por"
    end
  end

  describe "select/3 with the original-language sentinel" do
    test "resolves \"original\" to the item's original language" do
      streams = [video(), audio(1, "eng", is_default: true), audio(2, "jpn")]

      assert {:ok, track} =
               AudioTrackSelector.select(streams, ["original"], original_language: "ja")

      assert track.language == "jpn"
    end

    test "skips the sentinel when the item has no original language" do
      streams = [video(), audio(1, "rus", is_default: true), audio(2, "eng")]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["original", "en"])
      assert track.language == "eng"
    end

    test "prefers the original language ahead of English when both exist" do
      # Why "original" leads the shipped default: this must not hand an anime
      # viewer the English dub.
      streams = [video(), audio(1, "eng", is_default: true), audio(2, "jpn")]

      assert {:ok, track} =
               AudioTrackSelector.select(streams, ["original", "en"], original_language: "ja")

      assert track.language == "jpn"
    end
  end

  describe "select/3 fallbacks" do
    test "uses the container default when no preference matches" do
      streams = [video(), audio(1, "rus"), audio(2, "ita", is_default: true)]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["en"])
      assert track.language == "ita"
    end

    test "uses the first audio track when nothing matches and nothing is flagged" do
      streams = [video(), audio(1, "rus"), audio(2, "ita")]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["en"])
      assert track.index == 1
    end

    test "treats an empty preference list as no preference at all" do
      # Which is every mydia before this field existed: the container's flag
      # decides. Someone who liked that behaviour sets audio_language to [].
      streams = [video(), audio(1, "rus"), audio(2, "ita", is_default: true)]

      assert {:ok, track} = AudioTrackSelector.select(streams, [])
      assert track.language == "ita"
    end

    test "returns :none for a file with no audio at all" do
      assert :none = AudioTrackSelector.select([video()], ["en"])
    end

    test "returns :none for an empty stream list" do
      assert :none = AudioTrackSelector.select([], ["en"])
    end

    test "ignores an untagged track when a preference is set, but still falls back to it" do
      streams = [video(), audio(1, nil), audio(2, nil)]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["en"])
      assert track.index == 1
    end
  end

  describe "select/3 and commentary tracks" do
    test "never auto-selects a commentary track that matches the preference" do
      # A director's commentary is tagged with the same language as the film.
      # Matching on language alone would hand the viewer the commentary.
      streams = [
        video(),
        audio(1, "rus", is_default: true),
        audio(2, "eng", is_commentary: true, title: "Director's Commentary"),
        audio(3, "eng")
      ]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["en"])
      assert track.index == 3
    end

    test "falls back to a commentary track only when it is the sole audio stream" do
      streams = [video(), audio(1, "eng", is_commentary: true)]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["en"])
      assert track.index == 1
    end
  end

  describe "select/3 with prefer_default_track" do
    test "short-circuits to the flagged track, ignoring the preference" do
      # Jellyfin's "Play default audio track regardless of language" escape
      # hatch, for operators who tag their own files.
      streams = [video(), audio(1, "rus", is_default: true), audio(2, "eng")]

      assert {:ok, track} =
               AudioTrackSelector.select(streams, ["en"], prefer_default_track: true)

      assert track.language == "rus"
    end

    test "still applies the preference when nothing is flagged default" do
      streams = [video(), audio(1, "rus"), audio(2, "eng")]

      assert {:ok, track} =
               AudioTrackSelector.select(streams, ["en"], prefer_default_track: true)

      assert track.language == "eng"
    end
  end

  describe "select/3 tie-breaking between same-language tracks" do
    test "prefers the flagged track when two tracks share the language" do
      streams = [video(), audio(1, "eng", channels: 2), audio(2, "eng", is_default: true)]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["en"])
      assert track.index == 2
    end

    test "prefers more channels when neither same-language track is flagged" do
      streams = [video(), audio(1, "eng", channels: 2), audio(2, "eng", channels: 6)]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["en"])
      assert track.index == 2
    end

    test "prefers the earlier track when channels tie too" do
      streams = [video(), audio(1, "eng", channels: 6), audio(2, "eng", channels: 6)]

      assert {:ok, track} = AudioTrackSelector.select(streams, ["en"])
      assert track.index == 1
    end
  end

  describe "resolve_preferences/2" do
    test "per-show preference outranks every other source" do
      assert ["de"] =
               AudioTrackSelector.resolve_preferences(
                 show: ["de"],
                 device: ["fr"],
                 config: ["en"]
               )
    end

    test "per-device preference outranks the server config" do
      assert ["fr"] = AudioTrackSelector.resolve_preferences(device: ["fr"], config: ["en"])
    end

    test "falls back to the server config when nothing overrides it" do
      assert ["original", "en"] =
               AudioTrackSelector.resolve_preferences(config: ["original", "en"])
    end

    test "treats an empty list as an absent override, not as a silencing one" do
      # A device that has never been configured sends [], which must not read
      # as "this viewer wants no preference" and wipe the server's setting.
      assert ["en"] = AudioTrackSelector.resolve_preferences(device: [], config: ["en"])
    end

    test "returns an empty list when no source supplies a preference" do
      assert [] = AudioTrackSelector.resolve_preferences([])
    end
  end
end
