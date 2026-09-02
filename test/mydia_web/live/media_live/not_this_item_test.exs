defmodule MydiaWeb.MediaLive.NotThisItemTest do
  # Connected LiveView tests cannot be async under the PostgreSQL sandbox
  # (mirrors show_extras_test.exs / show_library_test.exs in this directory).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.Factory

  alias Mydia.Events
  alias Mydia.ImportCandidates
  alias Mydia.Library
  alias Mydia.Library.PathAnchor

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  test "refuses a file id belonging to a different media item", %{conn: conn} do
    library_path = insert(:library_path)
    on_screen = insert(:media_item, %{type: "movie", title: "Zephyr Station", year: 2030})
    other_item = insert(:media_item, %{type: "movie", title: "Emberline", year: 2029})

    # The victim: a file attached to an item the operator is not looking at.
    foreign_file =
      insert(:media_file, %{
        media_item_id: other_item.id,
        episode: nil,
        library_path_id: library_path.id,
        relative_path: "Emberline (2029)/Emberline.2029.1080p.mkv"
      })

    {:ok, view, _html} = live(conn, ~p"/media/#{on_screen.id}")

    # The id comes off the event payload, so a modified event can name any file.
    render_click(view, "not_this_item", %{"file-id" => foreign_file.id})

    # The foreign row is untouched and never reached the review inbox.
    assert Mydia.Repo.get(Mydia.Library.MediaFile, foreign_file.id)

    assert ImportCandidates.get_by_path(
             library_path.id,
             "Emberline (2029)/Emberline.2029.1080p.mkv"
           ) == nil
  end

  test "returns a wrongly attached file to the review inbox", %{conn: conn, user: user} do
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

    # And the file is now waiting in the review inbox at its current path,
    # carrying the item's type as a hint so a mixed-type library's match
    # search does not default it to "movie" (review finding 3).
    assert %{media_type: "movie"} =
             ImportCandidates.get_by_path(
               library_path.id,
               "Starveil (2031)/Starveil.2031.1080p.mkv"
             )

    # The activity trail (review finding 1): create_event_async runs
    # synchronously under the sandbox, so the event is already committed by
    # the time render_click/1 returns.
    assert [event] =
             Events.list_events(
               type: "media_file.returned_to_review",
               resource_type: "media_item",
               resource_id: item.id
             )

    assert event.actor_type == :user
    assert event.actor_id == to_string(user.id)
    assert event.metadata["title"] == "Zephyr Station"
    assert event.metadata["media_type"] == "movie"
    assert event.metadata["file_path"] == "Starveil (2031)/Starveil.2031.1080p.mkv"
    assert event.metadata["file_id"] == file.id
  end

  test "carries a TV show's type hint, not the default movie guess", %{conn: conn} do
    library_path = insert(:library_path, %{type: :mixed})
    item = insert(:tv_show, %{title: "Undertow"})

    file =
      insert(:media_file, %{
        media_item_id: item.id,
        episode: nil,
        library_path_id: library_path.id,
        relative_path: "Undertow/Season 01/Undertow.S01E01.mkv"
      })

    {:ok, view, _html} = live(conn, ~p"/tv/#{item.id}")

    view
    |> element("#not-this-item-#{file.id}")
    |> render_click()

    # ImportCandidate.parsed_info/1 defaults a nil media_type to :movie, so
    # without the fix this would silently come back "movie" instead of
    # crashing -- asserting the value directly is the only way to catch it.
    assert %{media_type: "tv_show"} =
             ImportCandidates.get_by_path(
               library_path.id,
               "Undertow/Season 01/Undertow.S01E01.mkv"
             )
  end

  test "an interruption between the two writes leaves neither committed" do
    library_path = insert(:library_path)
    item = insert(:media_item, %{type: "movie", title: "Zephyr Station", year: 2030})

    file =
      insert(:media_file, %{
        media_item_id: item.id,
        episode: nil,
        library_path_id: library_path.id,
        relative_path: "Interrupted (2031)/Interrupted.2031.1080p.mkv"
      })

    # There is no failure-injection point available here (no mocking library
    # in this project, and every foreign key this schema touches is either
    # enforced -- so a dangling reference cannot be constructed to force a
    # constraint error -- or self-healed by ImportCandidates.upsert/1's own
    # retry-as-update). So this exercises the exact two calls
    # FileEvents.not_this_item/2 composes inside one Mydia.Repo.transaction/1,
    # both of which genuinely run and would genuinely persist on their own,
    # and forces the abort explicitly to stand in for a hard interruption
    # (a killed process, a dropped connection) landing between them.
    absolute_path = Path.join(library_path.path, file.relative_path)
    anchor = PathAnchor.anchor_for(absolute_path, library_path.path)

    result =
      Mydia.Repo.transaction(fn ->
        {:ok, _candidate} =
          ImportCandidates.upsert(%{
            library_path_id: library_path.id,
            relative_path: file.relative_path,
            anchor_key: anchor.cluster_key,
            size: file.size,
            media_type: item.type,
            discovered_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        {:ok, _deleted} = Library.delete_media_file(file, delete_files: false)

        Mydia.Repo.rollback(:simulated_interruption)
      end)

    assert result == {:error, :simulated_interruption}

    # Neither write survived: the media_files row is still there...
    assert Mydia.Repo.get(Mydia.Library.MediaFile, file.id)
    # ...and no candidate was left behind either.
    refute ImportCandidates.get_by_path(library_path.id, file.relative_path)
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
