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

  @lantern_eng "[RAWG] Paper Lantern Club S01 ENG [WEB-DL 1080p HEVC AAC]"
  @lantern_italian "[RAWG] Paper Lantern Club S01 iTALiAN [WEB-DL 1080p HEVC AC3]"
  @lantern_untagged "[RAWG] Paper Lantern Club S01 [WEB-DL 1080p HEVC AAC]"

  @lantern_dual "[RAWG] Paper Lantern Club S01 [Dual Audio][WEB-DL 1080p HEVC AAC]"
  @lantern_jpn "[RAWG] Paper Lantern Club S01 JPN [WEB-DL 1080p HEVC AAC]"

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

  test "identity match is the outermost sort key, ahead of language" do
    correct_episode = "Kaiju.Garden.S03E12.1080p.CR.WEB-DL.JPN.AAC2.0.H.264-VARYG"
    wrong_episode_dual = "Kaiju.Garden.S03E11.1080p.CR.WEB-DL.DUAL.AAC2.0.H.264-VARYG"
    season_pack_dual = "[BlackRabbit] Kaiju Garden (2021) - S03 [Bluray-1080p][Dual Audio][AV1]"

    candidates = [
      result(correct_episode, 10, 1_400),
      result(wrong_episode_dual, 50, 1_400),
      result(season_pack_dual, 50, 33_600)
    ]

    opts =
      RankingOptions.build(%{
        media_type: :episode,
        quality_profile: hd_profile(),
        custom_formats: [],
        audio_policy: AudioLanguagePolicy.new(["en"], :show, "ja"),
        expected_season: 3,
        expected_episode: 12
      })

    best = ReleaseRanker.select_best_result(candidates, opts)
    assert best.result.title == correct_episode

    stats = ReleaseRanker.build_filter_stats(candidates, opts)
    assert [first | _] = stats["results"]
    assert first["title"] == correct_episode
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

  test "unknown original language leaves an untagged release unranked by language" do
    # original_language is nil here, so the "original" sentinel resolves to
    # nothing and the policy is effectively just ["en"]. An untagged release
    # (ReleaseLanguages.detect/2 returns languages: [], assumed?: true) has no
    # preferred language to match, so it lands at the worst rank - tying with
    # an explicitly foreign-only release - exactly like an unconsidered
    # release did before this branch. This is intended, not a regression: it
    # is only pinned here so it does not silently change.
    policy = AudioLanguagePolicy.new(["original", "en"], :server, nil)

    untagged = result(@lantern_untagged, 10, 4_000)
    italian = result(@lantern_italian, 10, 4_000)
    eng = result(@lantern_eng, 10, 4_000)

    opts = [media_type: :episode, quality_profile: hd_profile(), audio_policy: policy]

    ranked = ReleaseRanker.rank_all([untagged, italian, eng], opts)

    assert hd(ranked).result.title == @lantern_eng

    ranks = Map.new(ranked, &{&1.result.title, &1.breakdown.language_rank})
    assert ranks[@lantern_untagged] == 1
    assert ranks[@lantern_italian] == 1
  end

  test "Activity's filter stats break a language-rank tie on matches, not raw score" do
    # score_all_with_reasons/2 (behind build_filter_stats/2) used to sort by
    # {language_rank, -custom_format_score, -score}, omitting language_matches,
    # so a single-language release with a higher score could list above a
    # dual-audio release that rank_all/2 - and therefore the actual grab -
    # ranks first. Give the JPN-only release far more seeders so raw score
    # alone would put it first; the corrected sort must not let that happen.
    policy = AudioLanguagePolicy.new(["original", "en"], :server, "ja")

    dual = result(@lantern_dual, 10, 4_000)
    jpn = result(@lantern_jpn, 200, 4_000)

    opts = [media_type: :episode, quality_profile: hd_profile(), audio_policy: policy]

    stats = ReleaseRanker.build_filter_stats([dual, jpn], opts)

    assert [first | _] = stats["results"]
    assert first["title"] == @lantern_dual
  end

  describe "season pack size" do
    defp size_opts(extra) do
      Keyword.merge(
        [media_type: :episode, quality_profile: hd_profile(), size_range: {1024, 7680}],
        extra
      )
    end

    test "a pack within bounds per episode takes no size penalty" do
      pack = result(@varyg, 16, 35_000)

      assert ReleaseRanker.calculate_score_breakdown(pack, size_opts(episode_count: 24)).size_penalty ==
               0.0

      assert ReleaseRanker.calculate_score_breakdown(pack, size_opts([])).size_penalty < 0.0
    end

    test "a single episode is never divided, even in a season search" do
      episode = result("Kaiju.Garden.S02E01.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG", 16, 35_000)

      assert ReleaseRanker.calculate_score_breakdown(episode, size_opts(episode_count: 24)).size_penalty <
               0.0
    end

    test "RankingOptions passes the episode count through" do
      opts =
        RankingOptions.build(%{
          media_type: :episode,
          quality_profile: hd_profile(),
          custom_formats: [],
          audio_policy: nil,
          episode_count: 24
        })

      assert Keyword.get(opts, :episode_count) == 24
    end
  end
end
