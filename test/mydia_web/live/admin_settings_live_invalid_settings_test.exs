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

  test "an unusable row does not show a Database source badge", %{conn: conn} do
    # streaming.max_transcode_height has no environment variable set in this
    # test run, so its source badge is decided purely by whether the row
    # survives into `all_db_settings`. It keeps rendering the schema default
    # once the merge skips this row, so it must not also be tagged as coming
    # from the database: that would tell the operator two different things
    # about the same value on the same screen.
    Repo.insert!(%ConfigSetting{
      key: "streaming.max_transcode_height",
      value: "not-a-number",
      category: :streaming
    })

    {:ok, _view, html} = live(conn, ~p"/admin/config/settings")

    # Scope to this setting's own row via its value control's phx-value-key,
    # climbing to the row content div that also holds the source badge.
    # setting_source_badge/1 (components.ex) renders :database as
    # `badge badge-primary`, everything else (including :default) as
    # `badge badge-ghost`.
    row_html =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([phx-value-key="streaming.max_transcode_height"]))
      |> LazyHTML.parent_node()
      |> LazyHTML.parent_node()
      |> LazyHTML.parent_node()
      |> LazyHTML.to_html()

    refute row_html =~ "badge-primary"
    assert row_html =~ "badge-ghost"
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
