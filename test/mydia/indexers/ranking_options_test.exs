defmodule Mydia.Indexers.RankingOptionsTest do
  use Mydia.DataCase, async: true

  import ExUnit.CaptureLog
  import Mydia.SettingsFixtures

  alias Mydia.Indexers.RankingOptions
  alias Mydia.Settings.QualityProfile

  defp profile(attrs \\ %{}) do
    defaults = %{
      id: Ecto.UUID.generate(),
      name: "Test Profile",
      quality_standards: %{
        preferred_resolutions: ["1080p", "720p"]
      }
    }

    Map.merge(defaults, attrs) |> then(&struct!(QualityProfile, &1))
  end

  describe "build/1" do
    test "movie and episode builds share the same option shape for equivalent inputs" do
      common = %{
        quality_profile: profile(),
        min_seeders: 5,
        size_range: {100, 20_000},
        search_query: "Some Title",
        expected_title: "Some Title",
        blocked_tags: ["CAM"],
        preferred_tags: ["PROPER"]
      }

      movie = RankingOptions.build(Map.put(common, :media_type, :movie))
      episode = RankingOptions.build(Map.put(common, :media_type, :episode))

      for key <- [
            :min_seeders,
            :size_range,
            :search_query,
            :expected_title,
            :blocked_tags,
            :preferred_tags,
            :preferred_qualities
          ] do
        assert Keyword.get(movie, key) == Keyword.get(episode, key)
      end

      assert Keyword.get(movie, :media_type) == :movie
      assert Keyword.get(episode, :media_type) == :episode
    end

    test "episode and season inputs yield expected_season/expected_episode; movie does not" do
      episode =
        RankingOptions.build(%{
          media_type: :episode,
          expected_season: 9,
          expected_episode: 1
        })

      season =
        RankingOptions.build(%{
          media_type: :episode,
          expected_season: 9
        })

      movie = RankingOptions.build(%{media_type: :movie})

      assert Keyword.get(episode, :expected_season) == 9
      assert Keyword.get(episode, :expected_episode) == 1

      assert Keyword.get(season, :expected_season) == 9
      refute Keyword.has_key?(season, :expected_episode)

      refute Keyword.has_key?(movie, :expected_season)
      refute Keyword.has_key?(movie, :expected_episode)
    end

    test "min_ratio resolves from quality_standards (atom key)" do
      opts =
        RankingOptions.build(%{
          media_type: :episode,
          quality_profile: profile(%{quality_standards: %{min_ratio: 0.2}})
        })

      assert Keyword.get(opts, :min_ratio) == 0.2
    end

    test "min_ratio resolves from quality_standards (string key)" do
      opts =
        RankingOptions.build(%{
          media_type: :movie,
          quality_profile: profile(%{quality_standards: %{"min_ratio" => 0.3}})
        })

      assert Keyword.get(opts, :min_ratio) == 0.3
    end

    test "min_ratio absent from quality_standards yields no min_ratio option" do
      # Regression check: the movie job used to read min_ratio from profile.rules.
      # The single source is now quality_standards; a profile that doesn't set it
      # there produces no min_ratio option.
      opts =
        RankingOptions.build(%{
          media_type: :movie,
          quality_profile: profile(%{quality_standards: %{preferred_resolutions: ["1080p"]}})
        })

      refute Keyword.has_key?(opts, :min_ratio)
    end

    test "nil size bounds omit :size_range rather than passing nils" do
      opts =
        RankingOptions.build(%{
          media_type: :episode,
          size_range: nil,
          quality_profile:
            profile(%{quality_standards: %{episode_min_size_mb: nil, episode_max_size_mb: nil}})
        })

      # No usable bounds anywhere → size_range option is absent (nil base, no
      # quality override).
      assert Keyword.get(opts, :size_range) == nil
    end

    test "size_range derives from quality_standards per media type" do
      movie =
        RankingOptions.build(%{
          media_type: :movie,
          quality_profile:
            profile(%{quality_standards: %{movie_min_size_mb: 1000, movie_max_size_mb: 30_000}})
        })

      episode =
        RankingOptions.build(%{
          media_type: :episode,
          quality_profile:
            profile(%{quality_standards: %{episode_min_size_mb: 200, episode_max_size_mb: 4000}})
        })

      assert Keyword.get(movie, :size_range) == {1000, 30_000}
      assert Keyword.get(episode, :size_range) == {200, 4000}
    end

    test "nil/empty blocked and preferred tags are skipped" do
      opts =
        RankingOptions.build(%{
          media_type: :movie,
          blocked_tags: nil,
          preferred_tags: []
        })

      refute Keyword.has_key?(opts, :blocked_tags)
      refute Keyword.has_key?(opts, :preferred_tags)
    end

    test "without a quality profile, preferred_qualities/min_ratio are absent" do
      opts = RankingOptions.build(%{media_type: :movie, search_query: "x"})

      refute Keyword.has_key?(opts, :quality_profile)
      refute Keyword.has_key?(opts, :preferred_qualities)
      refute Keyword.has_key?(opts, :min_ratio)
    end
  end

  describe "preferred_qualities ordering" do
    # ReleaseRanker reads the position of a resolution in :preferred_qualities as
    # the primary sort key, so an ascending stored list made it grab the lowest
    # resolution on offer. Profiles do store ascending: the shipped "Any" preset
    # and the Admin editor's checkbox order both produce ascending lists.
    test "an ascending stored list is handed to the ranker descending" do
      opts =
        RankingOptions.build(%{
          media_type: :movie,
          quality_profile:
            profile(%{
              quality_standards: %{
                preferred_resolutions: ["360p", "480p", "576p", "720p", "1080p", "2160p"]
              }
            })
        })

      assert Keyword.get(opts, :preferred_qualities) == [
               "2160p",
               "1080p",
               "720p",
               "576p",
               "480p",
               "360p"
             ]
    end

    test "an already-descending stored list is left in best-first order" do
      opts =
        RankingOptions.build(%{
          media_type: :movie,
          quality_profile:
            profile(%{quality_standards: %{preferred_resolutions: ["2160p", "1080p", "720p"]}})
        })

      assert Keyword.get(opts, :preferred_qualities) == ["2160p", "1080p", "720p"]
    end

    test "unknown resolutions sort after every known one, deterministically" do
      opts =
        RankingOptions.build(%{
          media_type: :movie,
          quality_profile:
            profile(%{
              quality_standards: %{
                preferred_resolutions: ["zebra", "720p", "aardvark", "2160p"]
              }
            })
        })

      assert Keyword.get(opts, :preferred_qualities) == ["2160p", "720p", "aardvark", "zebra"]
    end

    test "a single-resolution profile is unaffected" do
      opts =
        RankingOptions.build(%{
          media_type: :movie,
          quality_profile: profile(%{quality_standards: %{preferred_resolutions: ["1080p"]}})
        })

      assert Keyword.get(opts, :preferred_qualities) == ["1080p"]
    end
  end

  describe "custom formats" do
    test "passes :custom_formats through when given" do
      formats = [%{slug: "lang-vff", name: "VFF", score: 100, reject: false, patterns: []}]

      opts =
        RankingOptions.build(%{
          media_type: :movie,
          quality_profile: quality_profile_fixture(),
          custom_formats: formats
        })

      assert Keyword.get(opts, :custom_formats) == formats
    end

    test "omits :custom_formats when the list is empty" do
      opts =
        RankingOptions.build(%{
          media_type: :movie,
          quality_profile: quality_profile_fixture(),
          custom_formats: []
        })

      refute Keyword.has_key?(opts, :custom_formats)
    end

    test "warns when a profile is given but the :custom_formats key is absent" do
      log =
        capture_log(fn ->
          RankingOptions.build(%{
            media_type: :movie,
            quality_profile: quality_profile_fixture()
          })
        end)

      assert log =~ "custom formats will be ignored"
    end

    test "does not warn when there is no profile" do
      log =
        capture_log(fn ->
          RankingOptions.build(%{media_type: :movie})
        end)

      refute log =~ "custom formats will be ignored"
    end
  end
end
