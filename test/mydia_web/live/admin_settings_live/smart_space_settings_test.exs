defmodule MydiaWeb.AdminSettingsLive.SmartSpaceSettingsTest do
  # Saving reloads the cached runtime config, which is global.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Settings

  setup %{conn: conn} do
    start_supervised!(Mydia.Indexers.Health)
    original_config = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original_config do
        Application.put_env(:mydia, :runtime_config, original_config)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp submit(view, params) do
    view |> element("#smart-space-form") |> render_submit(params)
  end

  test "renders the defaults", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    assert has_element?(view, "#smart-space-settings")
    refute has_element?(view, "#smart-space-enabled[checked]")
    assert has_element?(view, "#smart-space-unit option[value='season'][selected]")
    assert has_element?(view, "#smart-space-grace-days[value='7']")
    assert has_element?(view, "#smart-space-watched-by option[value='all_started'][selected]")
    assert has_element?(view, "#smart-space-selected-users")
  end

  test "enabling and setting the grace period persists", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    html = submit(view, %{"enabled" => "true", "grace_days" => "14"})

    assert html =~ "Setting updated successfully"
    config = Mydia.Config.get().smart_space
    assert config.enabled == true
    assert config.grace_days == 14
    assert Settings.get_config_setting_by_key("smart_space.unit") == nil
  end

  test "selected people persist and show as checked", %{conn: conn} do
    user = user_fixture()
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    submit(view, %{"watched_by" => "selected", "selected_users" => ["", user.username]})

    config = Mydia.Config.get().smart_space
    assert config.watched_by == "selected"
    assert config.selected_users == [user.username]

    assert has_element?(
             view,
             "#smart-space-selected-users input[value='#{user.username}'][checked]"
           )
  end

  test "selected with nobody picked shows an error and writes nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    submit(view, %{"watched_by" => "selected", "selected_users" => [""], "grace_days" => "3"})

    assert has_element?(view, "#smart-space-error")
    assert Settings.get_config_setting_by_key("smart_space.watched_by") == nil
    assert Settings.get_config_setting_by_key("smart_space.grace_days") == nil
  end

  test "an unknown username shows an error and writes nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    submit(view, %{"watched_by" => "selected", "selected_users" => ["nobody-here"]})

    assert has_element?(view, "#smart-space-error")
    assert Settings.get_config_setting_by_key("smart_space.watched_by") == nil
    assert Settings.get_config_setting_by_key("smart_space.selected_users") == nil
  end

  test "a negative grace period is rejected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    submit(view, %{"grace_days" => "-2"})

    assert has_element?(view, "#smart-space-error")
    assert Settings.get_config_setting_by_key("smart_space.grace_days") == nil
  end

  test "a key set by the environment shows ENV and is disabled", %{conn: conn} do
    original = System.get_env("SMART_SPACE_GRACE_DAYS")
    System.put_env("SMART_SPACE_GRACE_DAYS", "30")

    on_exit(fn ->
      if original,
        do: System.put_env("SMART_SPACE_GRACE_DAYS", original),
        else: System.delete_env("SMART_SPACE_GRACE_DAYS")
    end)

    {:ok, view, _html} = live(conn, ~p"/admin/settings")

    assert has_element?(view, "#smart-space-grace-days[disabled]")
    assert has_element?(view, "#smart-space-settings .badge", "ENV")

    submit(view, %{"grace_days" => "5"})
    assert Settings.get_config_setting_by_key("smart_space.grace_days") == nil
  end
end
