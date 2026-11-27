defmodule MydiaWeb.AdminSmartSpaceLiveTest do
  # Saving config reloads the cached runtime config, which is global.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.Playback.Progress
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.SmartSpace.Rules

  setup %{conn: conn, tmp_dir: tmp_dir} do
    original_config = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original_config do
        Application.put_env(:mydia, :runtime_config, original_config)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)

    %{
      conn: log_in_user(conn, admin_user_fixture()),
      root: root,
      lp: library_path_fixture(%{path: root, type: "series"}),
      viewer: user_fixture()
    }
  end

  defp put_setting(key, value) do
    {:ok, _} = Settings.upsert_config_setting(%{key: key, value: value, category: :general})
    {:ok, _} = Mydia.Config.Loader.reload()
  end

  # A one-episode season watched `watched_days_ago` days ago; with the default
  # 7 day grace it falls due in `7 - watched_days_ago` days.
  defp due_show(ctx, title, watched_days_ago, number \\ 3) do
    show = media_item_fixture(%{type: "tv_show", title: title})

    ep =
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: number,
        air_date: ~D[2020-01-01],
        monitored: true
      })

    rel = "#{System.unique_integer([:positive])}.mkv"
    File.write!(Path.join(ctx.root, rel), "aaaa")

    {:ok, _} =
      Library.create_scanned_media_file(%{
        relative_path: rel,
        library_path_id: ctx.lp.id,
        episode_id: ep.id,
        size: 4
      })

    at = DateTime.utc_now() |> DateTime.add(-watched_days_ago, :day) |> DateTime.truncate(:second)

    Repo.insert!(%Progress{
      user_id: ctx.viewer.id,
      episode_id: ep.id,
      watched: true,
      position_seconds: 0,
      duration_seconds: 100,
      completion_percentage: 0.0,
      last_watched_at: at
    })

    {show, ep}
  end

  @moduletag :tmp_dir

  test "a non-admin is sent away" do
    conn = log_in_user(build_conn(), user_fixture())
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/admin/smart-space")
  end

  test "shows the empty state with a settings link when no rule is enabled", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/smart-space")

    assert has_element?(view, "#smart-space-empty")
    assert has_element?(view, ~s|#smart-space-empty a[href="/admin/settings"]|)
  end

  test "lists an upcoming cleanup, keeps it, and removes the keep", %{conn: conn} = ctx do
    put_setting("smart_space.enabled", "true")
    {show, _ep} = due_show(ctx, "Harrowgate Nights", 4)
    row = "#{show.id}-1-"

    {:ok, view, _html} = live(conn, ~p"/admin/smart-space")

    assert has_element?(view, "#smart-space-summary")
    refute has_element?(view, "#smart-space-empty")
    assert render(view) =~ "Harrowgate Nights"
    assert render(view) =~ "in 3 days"

    view |> element(~s|#smart-space-upcoming button[id^="keep-#{row}"]|) |> render_click()

    refute render(view) =~ "in 3 days"
    assert [%{season_number: 1}] = Rules.list_keeps()

    view |> element("#smart-space-tab-kept") |> render_click()
    assert_patch(view, ~p"/admin/smart-space?tab=kept")
    assert has_element?(view, "#smart-space-keeps", "Harrowgate Nights")

    [keep] = Rules.list_keeps()
    view |> element("#unkeep-#{keep.id}") |> render_click()

    assert Rules.list_keeps() == []
    refute has_element?(view, "#smart-space-keeps", "Harrowgate Nights")

    view |> element("#smart-space-tab-upcoming") |> render_click()
    assert render(view) =~ "in 3 days"
  end

  test "an already eligible cleanup reads next run", %{conn: conn} = ctx do
    put_setting("smart_space.enabled", "true")
    due_show(ctx, "Ostrander Reach", 30)

    {:ok, _view, html} = live(conn, ~p"/admin/smart-space")
    assert html =~ "next run"
  end

  test "episode units show an SxxExx label and keep the episode", %{conn: conn} = ctx do
    put_setting("smart_space.enabled", "true")
    put_setting("smart_space.unit", "episode")
    {_show, ep} = due_show(ctx, "Quillfeather Bay", 4, 3)

    {:ok, view, html} = live(conn, ~p"/admin/smart-space")
    assert html =~ "S01E03"

    view |> element(~s|#smart-space-upcoming button[id^="keep-"]|) |> render_click()
    assert [%{episode_id: id}] = Rules.list_keeps()
    assert id == ep.id
  end
end
