defmodule MydiaWeb.MediaLive.Show.ManualSearchQualityGateTest do
  # async: false — mutates the global default-quality-profile config setting
  # and disables/creates indexer configs, both process-wide state (same
  # reasoning as Mydia.Jobs.MovieSearchTest's setup).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.IndexerMock
  alias Mydia.Settings

  setup %{conn: conn} do
    admin = admin_user_fixture()
    conn = log_in_user(conn, admin)

    # Disable all existing DB indexer configs so only our Bypass mock answers
    # (mirrors Mydia.Jobs.MovieSearchTest's setup).
    Settings.list_indexer_configs()
    |> Enum.reject(&Settings.runtime_config?/1)
    |> Enum.each(&Settings.update_indexer_config(&1, %{enabled: false}))

    bypass = Bypass.open()

    IndexerMock.mock_prowlarr_all(bypass,
      results: [
        IndexerMock.movie_result(%{title: "The Matrix", year: 1999, seeders: 50})
      ]
    )

    {:ok, _indexer} =
      Settings.create_indexer_config(%{
        name: "Test Movie Indexer",
        type: :prowlarr,
        base_url: "http://localhost:#{bypass.port}",
        api_key: "test-key",
        enabled: true
      })

    %{conn: conn}
  end

  test "an unstamped item's manual search modal shows the ranked score, not the seeders-only fallback",
       %{conn: conn} do
    default =
      quality_profile_fixture(%{
        name: "Default-#{System.unique_integer([:positive])}",
        quality_standards: %{preferred_resolutions: ["1080p"]}
      })

    {:ok, _} = Settings.set_default_quality_profile(default.id)

    movie = media_item_fixture(%{type: "movie", title: "The Matrix", year: 1999})
    assert movie.quality_profile_id == nil

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    render_click(view, "manual_search", %{})
    render_async(view)

    assert has_element?(view, "#manual-search-modal")
    assert has_element?(view, "#manual-search-results")

    # The score ring/breakdown only renders when the modal's `quality_profile`
    # attr is truthy (modals.ex gates on `@quality_profile`). The item itself
    # carries no profile, so this only renders if the modal is handed the
    # resolved default rather than the raw (nil) media_item.quality_profile —
    # that was the display-gate regression: ranking used the default while
    # the display gate still saw nil.
    assert has_element?(view, "#manual-search-results .radial-progress")
  end
end
