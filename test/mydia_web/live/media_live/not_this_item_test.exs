defmodule MydiaWeb.MediaLive.NotThisItemTest do
  # Connected LiveView tests cannot be async under the PostgreSQL sandbox
  # (mirrors show_extras_test.exs / show_library_test.exs in this directory).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.Factory

  alias Mydia.ImportCandidates

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  test "returns a wrongly attached file to the review inbox", %{conn: conn} do
    library_path = insert(:library_path)
    item = insert(:media_item, %{type: "movie", title: "Zephyr Station", year: 2030})

    file =
      insert(:media_file, %{
        media_item_id: item.id,
        episode: nil,
        library_path_id: library_path.id,
        relative_path: "Starveil (2031)/Starveil.2031.1080p.mkv"
      })

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    view
    |> element("#not-this-item-#{file.id}")
    |> render_click()

    # The row is gone from the library.
    assert Mydia.Repo.get(Mydia.Library.MediaFile, file.id) == nil

    # And the file is now waiting in the review inbox at its current path.
    assert %{} =
             ImportCandidates.get_by_path(
               library_path.id,
               "Starveil (2031)/Starveil.2031.1080p.mkv"
             )
  end

  test "keeps the file on disk", %{conn: conn} do
    # library_path_factory points at /media/libraryN, which does not exist on
    # disk, so this test needs a real temporary directory instead.
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "mydia_not_this_item_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(tmp_dir) end)

    library_path = insert(:library_path, %{path: tmp_dir})
    item = insert(:media_item, %{type: "movie", title: "Zephyr Station", year: 2030})

    file =
      insert(:media_file, %{
        media_item_id: item.id,
        episode: nil,
        library_path_id: library_path.id,
        relative_path: "Starveil (2031)/Starveil.2031.1080p.mkv"
      })

    on_disk = Path.join(library_path.path, "Starveil (2031)/Starveil.2031.1080p.mkv")
    File.mkdir_p!(Path.dirname(on_disk))
    File.write!(on_disk, "not really a video")

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    view
    |> element("#not-this-item-#{file.id}")
    |> render_click()

    assert File.exists?(on_disk)
  end

  test "shows a clear message instead of crashing for a legacy row with no library path",
       %{conn: conn} do
    item = insert(:media_item, %{type: "movie", title: "Zephyr Station", year: 2030})

    file =
      insert(:media_file, %{
        media_item_id: item.id,
        episode: nil,
        library_path_id: nil,
        relative_path: nil,
        path: "/legacy/movies/Zephyr Station (2030)/Zephyr.Station.2030.1080p.mkv"
      })

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    html =
      view
      |> element("#not-this-item-#{file.id}")
      |> render_click()

    assert html =~ "cannot be sent to Review"

    # The row is untouched: neither deleted nor sent anywhere.
    assert Mydia.Repo.get(Mydia.Library.MediaFile, file.id)
  end
end
