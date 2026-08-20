defmodule Mydia.Library.Prune.RankerTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.Prune.{Group, Ranker}

  defp group_of(file_attrs) do
    movie = media_item_fixture(%{type: "movie"})
    lp = library_path_fixture(%{type: "movies"})

    files =
      Enum.map(file_attrs, fn attrs ->
        attrs
        |> Map.merge(%{media_item_id: movie.id, library_path_id: lp.id})
        |> media_file_fixture()
      end)

    %Group{
      subject_type: :movie,
      subject_id: movie.id,
      subject: movie,
      media_item: Mydia.Repo.preload(movie, :episodes),
      files: Mydia.Repo.preload(files, :library_path)
    }
  end

  # Mirrors Mydia.Upgrades.ComparatorTest's profile/1: a usable profile with
  # every dimension filled in, so score_file/3 never bails out early.
  defp quality_profile(overrides \\ %{}) do
    default_standards = %{
      preferred_resolutions: ["2160p", "1080p", "720p"],
      preferred_video_codecs: ["h265", "h264"],
      preferred_audio_codecs: ["aac", "eac3"],
      preferred_audio_channels: ["5.1", "2.0"],
      preferred_sources: ["BluRay", "WEB-DL"],
      hdr_formats: ["dolby_vision", "hdr10"]
    }

    attrs =
      Map.merge(
        %{quality_standards: default_standards},
        Map.new(overrides)
      )

    quality_profile_fixture(attrs)
  end

  # Like group_of/1, but the movie carries `profile` as its quality profile,
  # so Ranker.decide/1 can take the :profile path.
  defp group_with_profile(profile, file_attrs) do
    movie = media_item_fixture(%{type: "movie", quality_profile_id: profile.id})
    lp = library_path_fixture(%{type: "movies"})

    files =
      Enum.map(file_attrs, fn attrs ->
        attrs
        |> Map.merge(%{media_item_id: movie.id, library_path_id: lp.id})
        |> media_file_fixture()
      end)

    %Group{
      subject_type: :movie,
      subject_id: movie.id,
      subject: movie,
      media_item: Mydia.Repo.preload(movie, [:episodes, :quality_profile]),
      files: Mydia.Repo.preload(files, :library_path)
    }
  end

  describe "decide/1 fallback ranking" do
    test "prefers higher resolution" do
      group =
        group_of([
          %{relative_path: "low.avi", resolution: "360p", codec: "mpeg4", bitrate: 2_006_830},
          %{relative_path: "high.mp4", resolution: "1080p", codec: "hevc", bitrate: 2_002_656}
        ])

      decision = Ranker.decide(group)

      assert decision.keeper.relative_path == "high.mp4"
      assert Enum.map(decision.losers, & &1.relative_path) == ["low.avi"]
      assert decision.ranker == :fallback
    end

    test "prefers higher bitrate over a more efficient codec" do
      # Jujutsu Kaisen S03E03. Ranking codec above bitrate would keep the
      # 520 MB av1 and trash an 8.8 Mbps source.
      group =
        group_of([
          %{
            relative_path: "kARiDo.mkv",
            resolution: "1080p",
            codec: "h264",
            bitrate: 8_817_626,
            size: 1_581_811_675
          },
          %{
            relative_path: "AniDub.mp4",
            resolution: "1080p",
            codec: "h264",
            bitrate: 4_981_199,
            size: 956_867_074
          },
          %{
            relative_path: "Sokudo.mkv",
            resolution: "1080p",
            codec: "av1",
            bitrate: 2_898_871,
            size: 520_011_219
          }
        ])

      decision = Ranker.decide(group)

      assert decision.keeper.relative_path == "kARiDo.mkv"
      assert length(decision.losers) == 2
    end

    test "falls through to size when resolution and bitrate tie" do
      group =
        group_of([
          %{
            relative_path: "small.mkv",
            resolution: "1080p",
            codec: "h264",
            bitrate: 4_000_000,
            size: 1_000_000
          },
          %{
            relative_path: "big.mkv",
            resolution: "1080p",
            codec: "h264",
            bitrate: 4_000_000,
            size: 2_000_000
          }
        ])

      assert Ranker.decide(group).keeper.relative_path == "big.mkv"
    end

    test "falls through to codec only when everything else ties" do
      group =
        group_of([
          %{
            relative_path: "h264.mkv",
            resolution: "1080p",
            codec: "h264",
            bitrate: 4_000_000,
            size: 1_000_000
          },
          %{
            relative_path: "av1.mkv",
            resolution: "1080p",
            codec: "av1",
            bitrate: 4_000_000,
            size: 1_000_000
          }
        ])

      assert Ranker.decide(group).keeper.relative_path == "av1.mkv"
    end

    test "is deterministic across runs on a total tie" do
      group =
        group_of([
          %{
            relative_path: "a.mkv",
            resolution: "1080p",
            codec: "h264",
            bitrate: 4_000_000,
            size: 1_000_000
          },
          %{
            relative_path: "b.mkv",
            resolution: "1080p",
            codec: "h264",
            bitrate: 4_000_000,
            size: 1_000_000
          }
        ])

      first = Ranker.decide(group).keeper.id
      assert Ranker.decide(group).keeper.id == first
    end

    test "treats a missing resolution as worst rather than best" do
      group =
        group_of([
          %{
            relative_path: "unknown.avi",
            resolution: nil,
            codec: nil,
            bitrate: nil,
            size: 900_000_000
          },
          %{
            relative_path: "known.mkv",
            resolution: "480p",
            codec: "mpeg4",
            bitrate: 1_874_724,
            size: 800_000_000
          }
        ])

      assert Ranker.decide(group).keeper.relative_path == "known.mkv"
    end
  end

  describe "decide/1 profile ranking" do
    test "ranks via Upgrades.Comparator when the media item has a quality profile" do
      profile = quality_profile()

      group =
        group_with_profile(profile, [
          %{
            relative_path: "low.mkv",
            resolution: "480p",
            codec: "mpeg4",
            audio_codec: nil,
            hdr_format: nil,
            size: 500_000_000
          },
          %{
            relative_path: "high.mkv",
            resolution: "4K",
            codec: "hevc",
            audio_codec: "aac",
            hdr_format: "Dolby Vision",
            size: 20_000_000_000
          }
        ])

      decision = Ranker.decide(group)

      assert decision.ranker == :profile
      assert decision.keeper.relative_path == "high.mkv"
      assert Enum.map(decision.losers, & &1.relative_path) == ["low.mkv"]
    end

    test "falls back for the whole group when any file is unscorable, rather than mixing scales" do
      profile = quality_profile()

      group =
        group_with_profile(profile, [
          %{
            relative_path: "analyzed.mkv",
            resolution: "1080p",
            codec: "h264",
            bitrate: 4_000_000,
            size: 1_000_000
          },
          %{
            relative_path: "unanalyzed.mkv",
            resolution: "480p",
            codec: "mpeg4",
            bitrate: 500_000,
            size: 400_000,
            # No analyzed_at means Comparator.score_file/3 returns
            # {:error, :unscorable} for this file. A group must never rank
            # one file on the profile's 0-100 scale and another on the
            # fallback's raw resolution/bitrate scale, so the whole group
            # must drop to :fallback.
            analyzed_at: nil
          }
        ])

      decision = Ranker.decide(group)

      assert decision.ranker == :fallback
      assert decision.keeper.relative_path == "analyzed.mkv"
    end
  end

  describe "decide/2 operator override" do
    test "honours an explicit keeper and re-derives the losers" do
      group =
        group_of([
          %{relative_path: "high.mkv", resolution: "1080p", codec: "hevc", bitrate: 8_000_000},
          %{relative_path: "low.mkv", resolution: "720p", codec: "h264", bitrate: 2_000_000}
        ])

      chosen = Enum.find(group.files, &(&1.relative_path == "low.mkv"))
      decision = Ranker.decide(group, chosen.id)

      assert decision.keeper.id == chosen.id
      assert Enum.map(decision.losers, & &1.relative_path) == ["high.mkv"]
    end

    test "ignores a keeper id that is not in the group" do
      group =
        group_of([
          %{relative_path: "high.mkv", resolution: "1080p", codec: "hevc", bitrate: 8_000_000},
          %{relative_path: "low.mkv", resolution: "720p", codec: "h264", bitrate: 2_000_000}
        ])

      assert Ranker.decide(group, Ecto.UUID.generate()).keeper.relative_path == "high.mkv"
    end
  end
end
