defmodule Mydia.Indexers.ReleaseRankerResolutionFloorTest do
  @moduledoc """
  A profile's `:min_resolution` is a hard floor on the automatic path.

  Before this, `min_resolution` fed scoring and the upgrade-violation list but
  gated nothing, and there is no minimum score to grab, so the top of a bad
  list was taken regardless. Paired with an untagged release scoring a neutral
  50 (better than an honestly-labelled out-of-range one at 25), that is how a
  monitored episode landed a 360p XviD on a 1080p-floor profile.

  Release names are anonymised; the shapes are what matter, and they are taken
  from a real `search.completed` event.
  """
  use ExUnit.Case, async: true

  alias Mydia.Indexers.{QualityParser, ReleaseRanker, SearchResult}
  alias Mydia.Settings.QualityProfile

  defp hd_1080p do
    %QualityProfile{
      name: "HD-1080p",
      quality_standards: %{
        episode_max_size_mb: 7680,
        episode_min_size_mb: 1024,
        excluded_sources: ["CAM", "Telesync", "Telecine", "Screener", "Workprint"],
        max_resolution: "1080p",
        min_resolution: "1080p",
        preferred_resolutions: ["1080p"],
        preferred_sources: ["BluRay", "WEB-DL"]
      }
    }
  end

  defp no_floor do
    %QualityProfile{
      name: "Any",
      quality_standards: %{
        preferred_resolutions: ["360p", "480p", "576p", "720p", "1080p", "2160p"]
      }
    }
  end

  defp result(title, size_mb, seeders, guid) do
    SearchResult.new(
      title: title,
      size: round(size_mb * 1_048_576),
      seeders: seeders,
      leechers: 0,
      download_url: "magnet:?xt=urn:btih:#{guid}",
      indexer: "Prowlarr",
      guid: guid,
      quality: QualityParser.parse(title)
    )
  end

  defp xvid_360p do
    result("Example.Show.2024.S02E01.Episode.Title.XviD-GRP[site.to].avi", 459.2, 0, "xvid")
  end

  defp x265_720p do
    result("Example.Show.2024.S02E01.720p.10bit.WEBRip.2CH.x265.HEVC-GRP.mkv", 269.8, 11, "psa")
  end

  defp web_dl_1080p do
    result(
      "www.SiteName.org    -    Example Show 2024 S02E01 Episode Title 1080p ATVP WEB-DL DDP5 1 Atmos H 264-GRP",
      4117.8,
      1,
      "webdl-1080p"
    )
  end

  defp opts(profile, extra \\ []) do
    Keyword.merge(
      [
        media_type: :episode,
        quality_profile: profile,
        preferred_qualities: ["1080p"],
        size_range: {1024, 7680},
        search_query: "Example Show (2024) S02E01",
        expected_title: "Example Show (2024)",
        expected_season: 2,
        expected_episode: 1,
        custom_formats: []
      ],
      extra
    )
  end

  describe "min_resolution is a hard floor on the automatic path" do
    test "a below-floor release is dropped even when it is the ONLY candidate" do
      # The item must stay wanted rather than take a 360p rip.
      assert ReleaseRanker.select_best_result([xvid_360p()], opts(hd_1080p())) == nil
    end

    test "an untagged release is treated as 360p and dropped by a 1080p floor" do
      assert xvid_360p().quality.resolution == nil
      assert ReleaseRanker.rank_all([xvid_360p()], opts(hd_1080p())) == []
    end

    test "every below-floor candidate is dropped, leaving nothing to grab" do
      assert ReleaseRanker.rank_all([xvid_360p(), x265_720p()], opts(hd_1080p())) == []
    end

    test "an at-floor release survives" do
      assert %{result: %SearchResult{guid: "webdl-1080p"}} =
               ReleaseRanker.select_best_result(
                 [xvid_360p(), x265_720p(), web_dl_1080p()],
                 opts(hd_1080p())
               )
    end

    test "a profile with no min_resolution keeps everything" do
      ranked = ReleaseRanker.rank_all([xvid_360p(), x265_720p()], opts(no_floor()))
      assert length(ranked) == 2
    end

    test "a nil profile keeps everything" do
      ranked =
        ReleaseRanker.rank_all(
          [xvid_360p(), x265_720p()],
          opts(nil) |> Keyword.delete(:quality_profile)
        )

      assert length(ranked) == 2
    end
  end

  describe "apply_resolution_floor opt-out (manual search is the escape hatch)" do
    test "apply_resolution_floor: false keeps a below-floor release" do
      ranked =
        ReleaseRanker.rank_all([xvid_360p()], opts(hd_1080p(), apply_resolution_floor: false))

      assert length(ranked) == 1
    end

    test "the floor defaults to on, so the automatic path keeps filtering" do
      assert ReleaseRanker.rank_all([xvid_360p()], opts(hd_1080p())) == []
    end
  end

  describe "an untagged release no longer outranks a labelled one" do
    test "the 720p beats the untagged XviD once the floor is lifted" do
      # Both are below a 1080p floor, so this is the no-floor profile. The
      # XviD used to win on a neutral 50 for "unknown" against the 720p's 25.
      [%{result: best} | _] =
        ReleaseRanker.rank_all([xvid_360p(), x265_720p()], opts(no_floor()))

      assert best.guid == "psa"
    end

    test "an untagged release sorts as 360p in the preference order" do
      ranked =
        ReleaseRanker.rank_all(
          [xvid_360p(), x265_720p()],
          opts(no_floor(), preferred_qualities: ["2160p", "1080p", "720p", "480p", "360p"])
        )

      assert Enum.map(ranked, & &1.result.guid) == ["psa", "xvid"]
    end
  end
end
