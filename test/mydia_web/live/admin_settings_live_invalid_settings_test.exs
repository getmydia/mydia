defmodule MydiaWeb.AdminSettingsLiveInvalidSettingsTest do
  # Connected LiveView tests must stay sync: the Postgres sandbox is only
  # shared with the mount process when the case is not async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Repo
  alias Mydia.Settings.ConfigSetting

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "no alert when every row is usable", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/config/settings")

    refute has_element?(view, "#invalid-config-settings")
  end

  test "an unusable row is listed with its key", %{conn: conn} do
    # Inserted through Repo, bypassing the changeset: after the write-side
    # validation this is the only way such a row exists.
    Repo.insert!(%ConfigSetting{key: "server.port", value: "abc", category: :server})

    {:ok, view, _html} = live(conn, ~p"/admin/config/settings")

    assert has_element?(view, "#invalid-config-settings")
    assert has_element?(view, "#invalid-config-setting-server-port")
  end

  test "deleting an unusable row removes it from the alert", %{conn: conn} do
    setting = Repo.insert!(%ConfigSetting{key: "server.port", value: "abc", category: :server})

    {:ok, view, _html} = live(conn, ~p"/admin/config/settings")

    view
    |> element("#delete-invalid-config-setting-server-port")
    |> render_click()

    refute has_element?(view, "#invalid-config-settings")
    refute Repo.get(ConfigSetting, setting.id)
  end
end
