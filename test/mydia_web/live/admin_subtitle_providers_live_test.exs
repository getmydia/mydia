defmodule MydiaWeb.AdminSubtitleProvidersLiveTest do
  # Connected LiveView tests must not be async. A non-shared PostgreSQL sandbox
  # hides rows inserted here from the mount process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Mydia.AccountsFixtures
  alias Mydia.SubtitleProviderFixtures

  setup %{conn: conn} do
    # Admin routes require :admin; the plan's user_fixture creates a regular user.
    user = AccountsFixtures.admin_user_fixture()
    {:ok, conn: log_in_user(conn, user)}
  end

  test "lists the registry defaults on a fresh install", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/subtitle-providers")

    assert has_element?(view, "#subtitle-provider-row-relay")
    assert has_element?(view, "#subtitle-provider-row-gestdown")
  end

  test "opens the editor modal", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/subtitle-providers")

    view |> element("#subtitle-provider-add") |> render_click()

    assert has_element?(view, "#subtitle-provider-form")
  end

  test "creates a SubDL provider with an api key", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/subtitle-providers")

    view |> element("#subtitle-provider-add") |> render_click()

    view
    |> form("#subtitle-provider-form", %{
      "subtitle_provider_config" => %{
        "name" => "My SubDL",
        "type" => "subdl",
        "api_key" => "abc123",
        "enabled" => "true",
        "priority" => "10"
      }
    })
    |> render_submit()

    assert has_element?(view, "#subtitle-provider-row-subdl")
  end

  test "rejects a SubDL provider with no api key", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/subtitle-providers")

    view |> element("#subtitle-provider-add") |> render_click()

    html =
      view
      |> form("#subtitle-provider-form", %{
        "subtitle_provider_config" => %{"name" => "Bad", "type" => "subdl", "api_key" => ""}
      })
      |> render_submit()

    assert html =~ "requires an API key"
  end

  test "toggles a provider off", %{conn: conn} do
    config = SubtitleProviderFixtures.config_fixture(%{name: "Toggle Me", type: :relay})

    {:ok, view, _html} = live(conn, ~p"/admin/subtitle-providers")

    view
    |> element("#subtitle-provider-toggle-#{config.id}")
    |> render_click()

    assert Mydia.Settings.ServiceConfigs.get_subtitle_provider_config!(config.id).enabled == false
  end
end
