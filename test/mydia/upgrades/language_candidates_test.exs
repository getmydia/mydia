defmodule Mydia.Upgrades.LanguageCandidatesTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{ReleaseLanguages, SearchResult}
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.{FileMetadata, Quality, StreamInfo}
  alias Mydia.Media.AudioLanguagePolicy
  alias Mydia.Settings.QualityProfile
  alias Mydia.Upgrades
  alias Mydia.Upgrades.Comparator

  @size 2 * 1024 * 1024 * 1024

  # A margin of 100 is unreachable, so every {:ok, _} under it is a language
  # decision and never a quality one.
  defp profile(margin) do
    %QualityProfile{
      name: "Language candidates",
      upgrades_allowed: true,
      upgrade_until_score: 85,
      min_upgrade_margin: margin,
      quality_standards: %{preferred_resolutions: ["1080p"]}
    }
  end

  defp file(languages, resolution \\ "1080p") do
    %MediaFile{
      resolution: resolution,
      codec: "h264",
      size: @size,
      analyzed_at: ~U[2026-07-01 00:00:00Z],
      metadata: %FileMetadata{streams: streams(languages)}
    }
  end

  defp streams(languages) do
    languages
    |> Enum.with_index(1)
    |> Enum.map(fn {language, index} ->
      %StreamInfo{index: index, type: :audio, language: language}
    end)
  end

  defp detected(languages, assumed? \\ false),
    do: %ReleaseLanguages{languages: languages, assumed?: assumed?}

  defp show_policy(languages), do: AudioLanguagePolicy.new(languages, :show, "ja")
  defp server_policy, do: AudioLanguagePolicy.new(["original", "en"], :server, "ja")

  defp judge(file, candidate, policy, reasons, margin \\ 100) do
    Comparator.upgrade?(file, %Quality{resolution: "1080p"}, @size, profile(margin), :episode,
      audio_policy: policy,
      candidate_languages: candidate,
      reasons: reasons
    )
  end

  describe "Comparator.upgrade?/6 language rules" do
    test "an explicit match for the show's language wins without clearing the margin" do
      assert {:ok, %{reason: :language}} =
               judge(file(["jpn"]), detected(["en", "ja"]), show_policy(["en"]), [:language])
    end

    test "an assumed detection wins only when the file carries no preferred language" do
      # Russian-only file under the server default: nothing watchable to lose.
      assert {:ok, %{reason: :language}} =
               judge(file(["rus"]), detected(["ja"], true), server_policy(), [:language])

      # English file under ["ja", "en"]: a guess must not replace it.
      assert {:error, :same_language} =
               judge(file(["eng"]), detected(["ja"], true), show_policy(["ja", "en"]), [:language])
    end

    test "a candidate that drops the file's language is refused, even for a quality search" do
      assert {:error, :drops_language} =
               judge(file(["eng"], "720p"), detected(["ja"]), show_policy(["en"]), [:quality], 0)
    end

    test "a language win does not count on a quality-only search" do
      assert {:error, :below_margin} =
               judge(file(["jpn"]), detected(["en"]), show_policy(["en"]), [:quality])
    end

    test "an equal rank is a quality question, asked only by a quality search" do
      current = file(["jpn"], "720p")

      assert {:error, :same_language} =
               judge(current, detected(["ja"]), server_policy(), [:language], 0)

      assert {:ok, %{reason: :quality, delta: delta}} =
               judge(current, detected(["ja"]), server_policy(), [:quality], 0)

      assert delta > 0

      assert {:error, :below_margin} =
               judge(current, detected(["ja"]), server_policy(), [:quality])
    end

    test "a file with untagged audio skips the language rules" do
      current = file([nil], "720p")

      assert {:error, :same_language} =
               judge(current, detected(["en"]), show_policy(["en"]), [:language])

      assert {:ok, %{reason: :quality}} =
               judge(current, detected(["en"]), show_policy(["en"]), [:quality], 0)
    end

    test "with no options it is the quality comparison it always was" do
      assert {:ok, %{reason: :quality}} =
               Comparator.upgrade?(
                 file(["jpn"], "720p"),
                 %Quality{resolution: "1080p"},
                 @size,
                 profile(0),
                 :movie
               )
    end
  end

  describe "Upgrades.filter_candidates/5 and upgrade_reason/5" do
    defp result(title, quality \\ %Quality{resolution: "1080p"}) do
      SearchResult.new(
        title: title,
        size: @size,
        seeders: 10,
        leechers: 1,
        download_url: "magnet:?xt=urn:btih:#{:erlang.phash2(title)}",
        indexer: "Test",
        quality: quality
      )
    end

    test "reads each title's audio and keeps only language wins for a language search" do
      current = file(["jpn"])
      opts = [audio_policy: show_policy(["en"]), reasons: [:language]]
      dub = result("Kaiju.Garden.S01E01.1080p.WEB-DL.English.Dub-GRP")
      raw = result("Kaiju.Garden.S01E01.1080p.WEB-DL.JPN-GRP")

      assert Upgrades.filter_candidates([dub, raw], current, profile(100), :episode, opts) == [
               dub
             ]

      assert Upgrades.upgrade_reason(dub, current, profile(100), :episode, opts) == :language
    end

    test "without options the filter is the quality comparison it always was" do
      current = file(["jpn"], "720p")
      raw = result("Kaiju.Garden.S01E01.1080p.WEB-DL.JPN-GRP")

      assert Upgrades.filter_candidates([raw], current, profile(0), :episode) == [raw]
      assert Upgrades.upgrade_reason(raw, current, profile(0), :episode) == :quality
    end

    test "a result whose title never parsed into a quality is dropped" do
      unparsed = result("Kaiju.Garden.S01E01.English.Dub-GRP", nil)
      opts = [audio_policy: show_policy(["en"]), reasons: [:language]]

      assert Upgrades.filter_candidates([unparsed], file(["jpn"]), profile(100), :episode, opts) ==
               []
    end
  end
end
