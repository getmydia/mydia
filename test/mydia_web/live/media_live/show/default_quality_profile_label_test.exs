defmodule MydiaWeb.MediaLive.Show.DefaultQualityProfileLabelTest do
  # async: false — mutates the global default-quality-profile config setting,
  # process-wide state (same reasoning as
  # ManualSearchQualityGateTest / Mydia.Jobs.MovieSearchTest's setup).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Settings

  # The blank "follow the default" choice in the quality-profile picker
  # modal. It has no DOM id of its own, but phx-value-profile-id="" uniquely
  # identifies it among the profile buttons. The modal only renders once
  # opened (it is a page-level dialog, not an anchored dropdown: see
  # MydiaWeb.MediaLive.Show.Components.hero_section/1), so every test here
  # must open it first.
  @blank_profile_button ~s{button[phx-click="update_quality_profile"][phx-value-profile-id=""]}

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin)}
  end

  test "shows the configured default's name, not the item's own stamped profile", %{conn: conn} do
    profile_a =
      quality_profile_fixture(%{name: "Profile A #{System.unique_integer([:positive])}"})

    profile_b =
      quality_profile_fixture(%{name: "Profile B #{System.unique_integer([:positive])}"})

    {:ok, _} = Settings.set_default_quality_profile(profile_b.id)

    # The item is stamped with profile A, while the system default is the
    # *different* profile B. The blank/default choice must describe the
    # configured default (B), never the item's own resolved profile (A) -
    # that conflation is the central hazard this task guards against.
    movie = media_item_fixture(%{type: "movie", quality_profile_id: profile_a.id})

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_click(view, "show_quality_profile_modal", %{})

    assert has_element?(view, @blank_profile_button, "Use default (#{profile_b.name})")
    refute has_element?(view, @blank_profile_button, "Use default (#{profile_a.name})")
  end

  test "shows \"No profile\" when no default is configured", %{conn: conn} do
    {:ok, _} = Settings.set_default_quality_profile(nil)

    movie = media_item_fixture(%{type: "movie"})

    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")
    render_click(view, "show_quality_profile_modal", %{})

    assert has_element?(view, @blank_profile_button, "No profile")
  end
end
