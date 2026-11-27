defmodule MydiaWeb.MediaLive.SeasonDeleteFilesTest do
  @moduledoc """
  The season header's "Delete season files" button and its confirmation dialog.
  """
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import MydiaWeb.Formatters, only: [format_file_size: 1]

  alias Mydia.Library
  alias Mydia.Library.{MediaFile, MediaFileEpisode}
  alias Mydia.Repo

  @gib 1024 * 1024 * 1024

  setup %{tmp_dir: tmp_dir} do
    trash_root = Path.join(tmp_dir, "trash")
    File.mkdir_p!(trash_root)
    Application.put_env(:mydia, :trash_dir, trash_root)
    on_exit(fn -> Application.delete_env(:mydia, :trash_dir) end)

    root = Path.join(tmp_dir, "lib")
    File.mkdir_p!(root)
    library_path = library_path_fixture(%{path: root, type: "series"})
    show = media_item_fixture(%{type: "tv_show", title: "Harbor Lantern Nights"})

    s1 = for n <- 1..3, do: episode_with_file(show, library_path, root, 1, n)
    s2 = for n <- 1..2, do: episode_with_file(show, library_path, root, 2, n)
    empty = episode_fixture(%{media_item_id: show.id, season_number: 3, episode_number: 1})

    %{show: show, s1: s1, s2: s2, empty: empty, root: root, library_path: library_path}
  end

  defp episode_with_file(show, library_path, root, season, number) do
    episode =
      episode_fixture(%{
        media_item_id: show.id,
        season_number: season,
        episode_number: number,
        monitored: true
      })

    name = "s#{season}e#{number}.mkv"
    File.write!(Path.join(root, name), "video")

    {:ok, file} =
      Library.create_scanned_media_file(%{
        relative_path: name,
        library_path_id: library_path.id,
        episode_id: episode.id,
        size: @gib
      })

    {episode, file}
  end

  defp open_dialog(conn, show) do
    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    view |> element("#season-1-delete-files") |> render_click()
    view
  end

  defp next_episode_id(view) do
    %{next_episode: %{id: id}} = :sys.get_state(view.pid).socket.assigns
    id
  end

  defp monitored?(episode), do: Repo.reload!(episode).monitored

  describe "visibility" do
    @describetag :tmp_dir

    test "button is hidden when the season has no files", %{conn: conn, show: show} do
      {conn, _user} = register_and_log_in_user(conn)
      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

      assert has_element?(view, "#season-1-delete-files")
      refute has_element?(view, "#season-3-delete-files")
    end

    test "hidden for a guest", %{conn: conn, show: show} do
      {conn, _guest} = register_and_log_in_user(conn, %{role: "guest"})
      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

      refute has_element?(view, "#season-1-delete-files")
    end
  end

  describe "authorization" do
    @describetag :tmp_dir

    test "a guest pushing the events directly trashes nothing", %{
      conn: conn,
      show: show,
      s1: s1
    } do
      {conn, _guest} = register_and_log_in_user(conn, %{role: "guest"})
      {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

      render_click(view, "show_season_delete_confirm", %{"season-number" => "1"})
      refute has_element?(view, "#season-delete-modal")

      render_click(view, "delete_season_files", %{})

      for {episode, file} <- s1 do
        assert is_nil(Repo.reload!(file).trashed_at)
        assert monitored?(episode)
      end
    end
  end

  describe "dialog" do
    @describetag :tmp_dir

    test "shows file count and total size", %{conn: conn, show: show} do
      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)

      text = view |> element("#season-delete-modal") |> render()
      assert text =~ "3 files"
      assert text =~ format_file_size(3 * @gib)
    end

    test "counts a multi-episode file once and leaves out one reaching another season", %{
      conn: conn,
      show: show,
      s1: [{_e1, f1}, {e2, _f2}, {_e3, f3}],
      s2: [{s2e1, _} | _]
    } do
      Repo.insert!(%MediaFileEpisode{media_file_id: f1.id, episode_id: e2.id})
      Repo.insert!(%MediaFileEpisode{media_file_id: f3.id, episode_id: s2e1.id})

      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)

      text = view |> element("#season-delete-modal") |> render()
      assert text =~ "2 files"
      assert text =~ format_file_size(2 * @gib)

      view |> element("#season-delete-confirm") |> render_click()

      refute is_nil(Repo.reload!(f1).trashed_at)
      assert is_nil(Repo.reload!(f3).trashed_at)
    end

    test "says how many files are skipped for holding another season", %{
      conn: conn,
      show: show,
      s1: [_, _, {_e3, f3}],
      s2: [{s2e1, _} | _]
    } do
      Repo.insert!(%MediaFileEpisode{media_file_id: f3.id, episode_id: s2e1.id})

      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)

      assert has_element?(view, "#season-delete-skipped", "1 file is skipped")
      refute has_element?(view, "#season-delete-all-skipped")
      refute has_element?(view, "#season-delete-confirm[disabled]")
    end

    test "opens with the confirm disabled when every file is skipped", %{
      conn: conn,
      show: show,
      s1: s1,
      s2: [{s2e1, _} | _]
    } do
      for {_episode, file} <- s1,
          do: Repo.insert!(%MediaFileEpisode{media_file_id: file.id, episode_id: s2e1.id})

      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)

      assert has_element?(view, "#season-delete-all-skipped")
      assert has_element?(view, "#season-delete-confirm[disabled]")

      render_click(view, "delete_season_files", %{})

      for {episode, file} <- s1 do
        assert is_nil(Repo.reload!(file).trashed_at)
        assert monitored?(episode)
      end
    end

    test "trash is selected and unmonitor is checked by default", %{conn: conn, show: show} do
      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)

      assert has_element?(view, "#season-delete-form input[value=trash][checked]")
      assert has_element?(view, "#season-delete-unmonitor[checked]")
    end

    test "cancel closes it", %{conn: conn, show: show} do
      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)

      render_click(view, "hide_season_delete_confirm", %{})
      refute has_element?(view, "#season-delete-modal")
    end
  end

  describe "confirming" do
    @describetag :tmp_dir

    test "trashes the season and unmonitors it", %{conn: conn, show: show, s1: s1, s2: s2} do
      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)
      view |> element("#season-delete-confirm") |> render_click()

      for {episode, file} <- s1 do
        reloaded = Repo.reload!(file)
        refute is_nil(reloaded.trashed_at)
        assert reloaded.trashed_reason == :manual
        refute monitored?(episode)
      end

      for {episode, file} <- s2 do
        assert is_nil(Repo.reload!(file).trashed_at)
        assert monitored?(episode)
      end

      refute has_element?(view, "#season-delete-modal")
    end

    test "the next episode moves past the removed season", %{
      conn: conn,
      show: show,
      s1: [{e1, _} | _],
      s2: [{s2e1, _} | _]
    } do
      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)
      assert next_episode_id(view) == e1.id

      view |> element("#season-delete-confirm") |> render_click()
      assert next_episode_id(view) == s2e1.id
    end

    test "stop monitoring spares episodes a skipped file still holds", %{
      conn: conn,
      show: show,
      s1: [{e1, _}, {e2, _}, {e3, f3}],
      s2: [{s2e1, _} | _]
    } do
      Repo.insert!(%MediaFileEpisode{media_file_id: f3.id, episode_id: s2e1.id})

      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)
      view |> element("#season-delete-confirm") |> render_click()

      refute monitored?(e1)
      refute monitored?(e2)
      assert monitored?(e3)
      assert monitored?(s2e1)
      assert is_nil(Repo.reload!(f3).trashed_at)
    end

    test "permanent delete whose disk delete fails keeps every covered episode monitored", %{
      conn: conn,
      show: show,
      s1: [{e1, _}, {e2, _}, {e3, _}],
      root: root,
      library_path: library_path
    } do
      locked = Path.join(root, "locked")
      File.mkdir_p!(locked)
      File.write!(Path.join(locked, "s1e1e2.mkv"), "video")

      {:ok, f} =
        Library.create_scanned_media_file(%{
          relative_path: "locked/s1e1e2.mkv",
          library_path_id: library_path.id,
          episode_id: e1.id,
          size: 5
        })

      Repo.insert!(%MediaFileEpisode{media_file_id: f.id, episode_id: e2.id})
      File.chmod!(locked, 0o500)
      on_exit(fn -> File.chmod(locked, 0o700) end)

      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)

      view
      |> form("#season-delete-form", %{"file_delete_mode" => "permanent", "unmonitor" => "true"})
      |> render_change()

      view |> element("#season-delete-confirm") |> render_click()

      assert File.exists?(Path.join(locked, "s1e1e2.mkv"))
      assert monitored?(e1)
      assert monitored?(e2)
      refute monitored?(e3)
    end

    test "unchecking unmonitor keeps the season monitored", %{conn: conn, show: show, s1: s1} do
      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)

      view
      |> form("#season-delete-form", %{"file_delete_mode" => "trash", "unmonitor" => "false"})
      |> render_change()

      view |> element("#season-delete-confirm") |> render_click()

      for {episode, file} <- s1 do
        refute is_nil(Repo.reload!(file).trashed_at)
        assert monitored?(episode)
      end
    end

    test "permanent mode deletes rows", %{conn: conn, show: show, s1: s1, root: root} do
      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)

      view
      |> form("#season-delete-form", %{"file_delete_mode" => "permanent", "unmonitor" => "true"})
      |> render_change()

      view |> element("#season-delete-confirm") |> render_click()

      for {_episode, file} <- s1 do
        assert is_nil(Repo.get(MediaFile, file.id))
      end

      refute File.exists?(Path.join(root, "s1e1.mkv"))
    end

    test "library only keeps the bytes on disk", %{conn: conn, show: show, root: root} do
      {conn, _user} = register_and_log_in_user(conn)
      view = open_dialog(conn, show)

      view
      |> form("#season-delete-form", %{"file_delete_mode" => "library_only"})
      |> render_change()

      view |> element("#season-delete-confirm") |> render_click()

      assert File.exists?(Path.join(root, "s1e1.mkv"))
    end
  end
end
