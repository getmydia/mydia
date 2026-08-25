defmodule MydiaWeb.MediaLive.Show.RecommendationsExpandedTest do
  @moduledoc """
  The remount is the point. A test that only clicks the toggle and re-reads the
  same socket passes even when the state never leaves memory, which is exactly
  the bug this change fixes.
  """

  # async: false - the Postgres non-shared sandbox hides these rows from the
  # LiveView mount process otherwise.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  setup %{conn: conn} do
    # The app disables Oban in test (engine: false), so Oban.insert cannot run
    # from the LiveView process. Start an isolated, manual-mode instance so the
    # recommendations load can enqueue without a live queue.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    user = admin_user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp show_with_recommendations do
    source_tmdb_id = unique_provider_id()

    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "Detectorists",
        year: 2014,
        tmdb_id: source_tmdb_id
      })

    episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

    warm_recommendations_cache(source_tmdb_id, :tv_show, [
      %{
        "id" => unique_provider_id(),
        "name" => "Rev.",
        "first_air_date" => "2010-06-28",
        "poster_path" => "/p.jpg"
      }
    ])

    show
  end

  test "the rail starts collapsed for a show", %{conn: conn} do
    show = show_with_recommendations()

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    assert has_element?(view, ~s(#recommendations-rail-toggle[aria-expanded="false"]))
  end

  test "opening the rail persists and survives a remount", %{conn: conn, user: user} do
    show = show_with_recommendations()

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    view |> element("#recommendations-rail-toggle") |> render_click()

    assert user
           |> Accounts.get_user_preference!()
           |> UserPreference.recommendations_expanded() == true

    {:ok, remounted, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(remounted, 5000)

    assert has_element?(remounted, ~s(#recommendations-rail-toggle[aria-expanded="true"]))
  end

  test "closing the rail again persists false", %{conn: conn, user: user} do
    show = show_with_recommendations()

    {:ok, _} =
      Accounts.update_preference(
        Accounts.get_user_preference!(user),
        %{"recommendations_expanded" => true}
      )

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)

    view |> element("#recommendations-rail-toggle") |> render_click()

    assert user
           |> Accounts.get_user_preference!()
           |> UserPreference.recommendations_expanded() == false
  end

  # Asserts on the changeset directly rather than via errors_on/1: that helper
  # lives in Mydia.DataCase and MydiaWeb.ConnCase does not import it.
  test "a non-boolean value is rejected by the changeset", %{user: user} do
    assert {:error, %Ecto.Changeset{valid?: false} = changeset} =
             Accounts.update_preference(
               Accounts.get_user_preference!(user),
               %{"recommendations_expanded" => "yes"}
             )

    assert Keyword.has_key?(changeset.errors, :preferences)
  end
end
