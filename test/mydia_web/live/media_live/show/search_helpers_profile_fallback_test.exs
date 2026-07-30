defmodule MydiaWeb.MediaLive.Show.SearchHelpersProfileFallbackTest do
  # Separate from search_helpers_test.exs, which is deliberately DB-free.
  # This one needs the repo because the fallback reads the instance default.
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.QualityProfile
  alias MydiaWeb.MediaLive.Show.SearchHelpers

  defp assigns_for(media_item) do
    %{
      media_item: media_item,
      manual_search_context: %{type: :media_item},
      min_seeders: nil,
      manual_search_query: "Some Movie"
    }
  end

  test "a profile-less item ranks against the instance default's size bounds" do
    default =
      quality_profile_fixture(%{
        name: "instance-default",
        quality_standards: %{
          preferred_resolutions: ["1080p"],
          movie_min_size_mb: 500,
          movie_max_size_mb: 8000
        }
      })

    {:ok, _} = Settings.set_default_quality_profile(default.id)

    media_item =
      media_item_fixture(%{type: "movie"})
      |> Repo.preload(:quality_profile)

    assert is_nil(media_item.quality_profile)

    opts = SearchHelpers.build_manual_ranking_opts(assigns_for(media_item))

    assert %QualityProfile{} = Keyword.get(opts, :quality_profile)
    assert Keyword.get(opts, :size_range) == {500, 8000}
    assert Keyword.get(opts, :preferred_qualities) == ["1080p"]
  end

  test "an item with its own profile is unaffected by the instance default" do
    own =
      quality_profile_fixture(%{
        name: "own-profile",
        quality_standards: %{
          preferred_resolutions: ["1080p"],
          movie_min_size_mb: 100,
          movie_max_size_mb: 2000
        }
      })

    other =
      quality_profile_fixture(%{
        name: "instance-default",
        quality_standards: %{
          preferred_resolutions: ["1080p"],
          movie_min_size_mb: 500,
          movie_max_size_mb: 8000
        }
      })

    {:ok, _} = Settings.set_default_quality_profile(other.id)

    media_item =
      media_item_fixture(%{type: "movie", quality_profile_id: own.id})
      |> Repo.preload(:quality_profile)

    opts = SearchHelpers.build_manual_ranking_opts(assigns_for(media_item))

    assert Keyword.get(opts, :size_range) == {100, 2000}
  end
end
