defmodule MydiaWeb.MediaLive.Show.RenameModalTest do
  # async: false: connected LiveView tests need the shared sandbox.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Library
  alias Mydia.Library.FileRenamer
  alias Mydia.Repo

  @moduletag :tmp_dir

  setup %{conn: conn, tmp_dir: root} do
    # The app disables Oban in test (engine: false), so Oban.insert cannot run
    # from the LiveView process. Start an isolated, manual-mode instance so
    # anything the show page mount enqueues doesn't crash for lack of a queue.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Repo, engine: engine, testing: :manual})

    library_path = library_path_fixture(%{path: root, type: "series"})
    show = media_item_fixture(%{type: "tv_show", title: "The Lantern Keepers", year: 2021})

    make = fn season, episode, filename ->
      ep =
        episode_fixture(%{
          media_item_id: show.id,
          season_number: season,
          episode_number: episode
        })

      File.write!(Path.join(root, filename), "bytes")

      media_file_fixture(%{
        episode_id: ep.id,
        library_path_id: library_path.id,
        relative_path: filename
      })
    end

    s1e1 = make.(1, 1, "keepers-one.mkv")
    s1e2 = make.(1, 2, "keepers-two.mkv")
    s2e1 = make.(2, 1, "keepers-three.mkv")
    s2e2 = make.(2, 2, "keepers-four.mkv")

    # s1e2 already has its proposed name, so it is not selectable.
    preview = FileRenamer.generate_rename_preview(s1e2)
    File.rename!(preview.current_path, preview.proposed_path)
    {:ok, s1e2} = Library.update_media_file(s1e2, %{relative_path: preview.proposed_filename})

    admin = admin_user_fixture()

    %{
      conn: log_in_user(conn, admin),
      show: show,
      root: root,
      files: %{s1e1: s1e1, s1e2: s1e2, s2e1: s2e1, s2e2: s2e2}
    }
  end

  defp open_modal(ctx) do
    {:ok, view, _html} = live(ctx.conn, "/media/#{ctx.show.id}")
    view |> element("#rename-files-button") |> render_click()
    view
  end

  defp checked?(view, id), do: has_element?(view, "##{id}[checked]")

  test "preselects only the files whose name would change", ctx do
    view = open_modal(ctx)
    %{s1e1: a, s1e2: same, s2e1: c, s2e2: d} = ctx.files

    assert checked?(view, "rename-file-#{a.id}")
    assert checked?(view, "rename-file-#{c.id}")
    assert checked?(view, "rename-file-#{d.id}")
    refute has_element?(view, "#rename-file-#{same.id}")
    assert view |> element("#rename-selected-count") |> render() =~ "3 selected"
  end

  test "the season toggle clears, then refills, only that season", ctx do
    view = open_modal(ctx)
    %{s1e1: a, s2e1: c, s2e2: d} = ctx.files

    view |> element("#rename-season-2-toggle") |> render_click()
    refute checked?(view, "rename-file-#{c.id}")
    refute checked?(view, "rename-file-#{d.id}")
    assert checked?(view, "rename-file-#{a.id}")

    view |> element("#rename-season-2-toggle") |> render_click()
    assert checked?(view, "rename-file-#{c.id}")
    assert checked?(view, "rename-file-#{d.id}")
  end

  test "confirming renames Season 2 and leaves Season 1 untouched", ctx do
    view = open_modal(ctx)
    %{s1e1: a, s2e1: c} = ctx.files

    view |> element("#rename-file-#{a.id}") |> render_click()
    view |> element("#rename-confirm") |> render_click()
    render_async(view)

    assert Repo.reload(a).relative_path == "keepers-one.mkv"
    assert File.exists?(Path.join(ctx.root, "keepers-one.mkv"))

    renamed = Repo.reload(c)
    refute renamed.relative_path == "keepers-three.mkv"
    assert File.exists?(Path.join(ctx.root, renamed.relative_path))
    refute File.exists?(Path.join(ctx.root, "keepers-three.mkv"))
  end

  test "Rename is disabled with nothing selected", ctx do
    view = open_modal(ctx)

    view |> element("#rename-clear") |> render_click()
    assert has_element?(view, "#rename-confirm[disabled]")

    view |> element("#rename-select-all") |> render_click()
    refute has_element?(view, "#rename-confirm[disabled]")
  end
end
