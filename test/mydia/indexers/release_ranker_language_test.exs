defmodule Mydia.Indexers.ReleaseRankerLanguageTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{QualityParser, RankingOptions, ReleaseRanker, SearchResult}
  alias Mydia.Media.AudioLanguagePolicy
  alias Mydia.Settings.QualityProfile

  @mb 1024 * 1024

  @feibanyama "[Feibanyama] Kaiju Garden S02 [BILIBILI WebRip 2160p HEVC OPUS Multi-Subs]"
  @blackrabbit "[BlackRabbit] Kaiju Garden (2021) - S02 [Bluray-1080p][Opus 2.0][Dual Audio][AV1]"
  @tsundere "Kaiju Garden S02 MULTi 1080p WEB x264 AAC -Tsundere-Raws (CR)"
  @varyg "Kaiju.Garden.S02.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG"
  @italian "Kaiju Garden S02 Parte 1 (2023) 1080p WEBDL x265 iTALiAN AC3 iDN_CreW"
  @english_dub "[TRC] Kaiju Garden - S02 [English Dub] [CR WEB-RIP 1080p HEVC-10 AAC]"

  # Shaped like the season pack search that grabbed a Japanese-only 2160p pack
  # over five English-audio ones.
  defp candidates do
    [
      result(@feibanyama, 80, 49_685),
      result(@blackrabbit, 25, 3_912),
      result(@tsundere, 20, 33_564),
      result(@varyg, 16, 35_601),
      result(@italian, 9, 4_188),
      result(@english_dub, 8, 13_329)
    ]
  end

  defp result(title, seeders, size_mb) do
    %SearchResult{
      title: title,
      size: size_mb * @mb,
      seeders: seeders,
      leechers: 0,
      download_url: "magnet:?xt=urn:btih:#{:erlang.phash2(title)}",
      indexer: "TestIndexer",
      quality: QualityParser.parse(title)
    }
  end

  defp hd_profile do
    %QualityProfile{
      id: Ecto.UUID.generate(),
      name: "HD-1080p",
      quality_standards: %{
        episode_min_size_mb: 1024,
        episode_max_size_mb: 7680,
        min_resolution: "1080p",
        max_resolution: "1080p",
        preferred_resolutions: ["1080p"],
        preferred_sources: ["BluRay", "WEB-DL"]
      }
    }
  end

  defp ranked_titles(policy) do
    opts =
      RankingOptions.build(%{
        media_type: :episode,
        quality_profile: hd_profile(),
        custom_formats: [],
        audio_policy: policy,
        expected_season: 2
      })

    candidates()
    |> ReleaseRanker.rank_all(opts)
    |> Enum.map(& &1.result.title)
  end

  test "the server default prefers dual audio and puts other dubs last" do
    titles = ranked_titles(AudioLanguagePolicy.new(["original", "en"], :server, "ja"))

    assert hd(titles) == @blackrabbit

    assert Enum.find_index(titles, &(&1 == @varyg)) <
             Enum.find_index(titles, &(&1 == @english_dub))

    assert List.last(titles) == @italian
  end

  test "an English-first show override puts dual audio and the English dub on top" do
    titles = ranked_titles(AudioLanguagePolicy.new(["en"], :show, "ja"))

    assert titles |> Enum.take(2) |> MapSet.new() == MapSet.new([@blackrabbit, @english_dub])
    assert Enum.find_index(titles, &(&1 == @varyg)) > 1
  end

  test "language outranks resolution preference" do
    titles = ranked_titles(AudioLanguagePolicy.new(["original", "en"], :server, "ja"))

    # The 2160p pack misses the profile's only preferred resolution (1080p) but
    # carries the first preferred language; the 1080p English dub carries only
    # the second. Resolution-first sorting put the dub on top; language-first
    # must not.
    assert Enum.find_index(titles, &(&1 == @feibanyama)) <
             Enum.find_index(titles, &(&1 == @english_dub))
  end

  test "without a policy every release ranks 0 and no language is counted" do
    opts = [media_type: :episode, quality_profile: hd_profile()]

    for result <- candidates() do
      breakdown = ReleaseRanker.calculate_score_breakdown(result, opts)
      assert breakdown.language_rank == 0
      assert breakdown.language_matches == 0
    end
  end

  test "the breakdown records detected audio and whether it was assumed" do
    policy = AudioLanguagePolicy.new(["original", "en"], :server, "ja")
    opts = [media_type: :episode, audio_policy: policy]

    dual = ReleaseRanker.calculate_score_breakdown(result(@blackrabbit, 25, 3_912), opts)
    assert dual.audio_languages == ["en", "ja"]
    refute dual.audio_assumed
    assert dual.language_matches == 2

    untagged = ReleaseRanker.calculate_score_breakdown(result(@varyg, 16, 35_601), opts)
    assert untagged.audio_languages == ["ja"]
    assert untagged.audio_assumed
  end

  test "filter-stat rows carry the audio fields and sort by language rank" do
    policy = AudioLanguagePolicy.new(["en"], :show, "ja")

    stats =
      ReleaseRanker.build_filter_stats(candidates(), audio_policy: policy, media_type: :episode)

    [first | _] = stats["results"]

    assert first["language_rank"] == 0
    assert first["audio_assumed"] == false
    assert "en" in first["audio_languages"]
  end
end
