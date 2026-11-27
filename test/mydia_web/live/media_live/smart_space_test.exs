defmodule MydiaWeb.MediaLive.SmartSpaceTest do
  @moduledoc """
  Smart Space controls on the TV show page: the override menu entry and modal,
  the "cleans up in" badge on season headers, and the Keep toggles.
  """
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

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
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
      root: root,
      lp: library_path_fixture(%{path: root, type: "series"}),
      viewer: user_fixture()
    }
  end

  defp put_setting(key, value) do
    {:ok, _} = Settings.upsert_config_setting(%{key: key, value: value, category: :general})
    {:ok, _} = Mydia.Config.Loader.reload()
  end

  defp enable_smart_space, do: put_setting("smart_space.enabled", "true")

  # A one-episode season watched `watched_days_ago` days ago; with the default
  # 7 day grace it falls due in `7 - watched_days_ago` days.
  defp due_show(ctx, title, watched_days_ago) do
    show = media_item_fixture(%{type: "tv_show", title: title})

    ep =
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: 1,
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

  defp open_page(conn, show) do
    {conn, _user} = register_and_log_in_user(conn)
    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    view
  end

  test "the menu entry shows the inherited rule", %{conn: conn} = ctx do
    enable_smart_space()
    {show, _ep} = due_show(ctx, "Harrowgate Nights", 4)

    view = open_page(conn, show)

    assert has_element?(view, "#smart-space-menu", "Smart Space: Inherit (season, 7 days)")
  end

  test "choosing Off persists an override and hides the badges", %{conn: conn} = ctx do
    enable_smart_space()
    {show, _ep} = due_show(ctx, "Harrowgate Nights", 4)

    view = open_page(conn, show)
    assert has_element?(view, "#season-1-smart-space-due")

    view |> element("#smart-space-menu") |> render_click()
    assert has_element?(view, "#smart-space-modal")

    view
    |> form("#smart-space-override-form", smart_space: %{mode: "off"})
    |> render_submit()

    refute has_element?(view, "#smart-space-modal")
    assert %{mode: "off"} = Rules.get_override(show.id)
    refute has_element?(view, "#season-1-smart-space-due")
    refute has_element?(view, "#season-1-keep")
    assert has_element?(view, "#smart-space-menu", "Smart Space: Off")
  end

  test "Custom with episode and 3 days persists and shows episode toggles",
       %{conn: conn} = ctx do
    {show, ep} = due_show(ctx, "Ostrander Reach", 4)

    view = open_page(conn, show)
    refute has_element?(view, "#episode-#{ep.id}-keep")

    view |> element("#smart-space-menu") |> render_click()

    view
    |> form("#smart-space-override-form",
      smart_space: %{mode: "custom", unit: "episode", grace_days: "3"}
    )
    |> render_submit()

    assert %{mode: "custom", unit: "episode", grace_days: 3} = Rules.get_override(show.id)
    assert has_element?(view, "#smart-space-menu", "Smart Space: Custom (episode, 3 days)")
    assert has_element?(view, "#episode-#{ep.id}-keep")
    refute has_element?(view, "#season-1-keep")
  end

  test "a season due in 2 days shows a badge", %{conn: conn} = ctx do
    enable_smart_space()
    {show, _ep} = due_show(ctx, "Quillfeather Bay", 5)

    view = open_page(conn, show)

    assert has_element?(view, "#season-1-smart-space-due", "in 2 days")
  end

  test "an already eligible season reads next run", %{conn: conn} = ctx do
    enable_smart_space()
    {show, _ep} = due_show(ctx, "Quillfeather Bay", 30)

    view = open_page(conn, show)

    assert has_element?(view, "#season-1-smart-space-due", "next run")
  end

  test "the season keep toggle creates a keep, hides the badge, and toggles back",
       %{conn: conn} = ctx do
    enable_smart_space()
    {show, _ep} = due_show(ctx, "Quillfeather Bay", 5)

    view = open_page(conn, show)
    view |> element("#season-1-keep") |> render_click()

    assert [%{season_number: 1}] = Rules.list_keeps(media_item_id: show.id)
    refute has_element?(view, "#season-1-smart-space-due")

    view |> element("#season-1-keep") |> render_click()

    assert Rules.list_keeps(media_item_id: show.id) == []
    assert has_element?(view, "#season-1-smart-space-due")
  end

  test "a guest cannot open the editor or keep", %{conn: conn} = ctx do
    enable_smart_space()
    {show, _ep} = due_show(ctx, "Quillfeather Bay", 5)

    {conn, _guest} = register_and_log_in_user(conn, %{role: "guest"})
    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    refute has_element?(view, "#season-1-keep")
    render_click(view, "smart_space_open", %{})
    refute has_element?(view, "#smart-space-modal")
  end

  test "a movie page has no Smart Space controls", %{conn: conn} do
    enable_smart_space()
    movie = media_item_fixture(%{type: "movie", title: "Lanternfish Harbor"})

    view = open_page(conn, movie)

    refute has_element?(view, "#smart-space-menu")
  end
end
