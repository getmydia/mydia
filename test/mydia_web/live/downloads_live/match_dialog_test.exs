defmodule MydiaWeb.DownloadsLive.MatchDialogTest do
  # async: false because later tasks in this file register a global stub
  # metadata provider through Provider.Registry, which is an Agent.
  use Mydia.DataCase, async: false

  alias MydiaWeb.DownloadsLive.MatchDialog

  import Mydia.MediaFixtures
  import Mydia.MetadataStub, only: [setup_metadata_stub: 1]

  defp dialog_for(type) do
    %MatchDialog{download_id: "d1", mode: :inflight, query: "", type: type}
  end

  describe "open/2" do
    test "seeds the query from the parsed release title" do
      download = %{id: "d1", title: "Show.Name.S01-S03.1080p.WEB-DL.x265", media_item: nil}

      dialog = MatchDialog.open(download, :inflight)

      assert dialog.query == "Show Name"
      assert dialog.type == :tv_show
      assert dialog.mode == :inflight
      assert dialog.download_id == "d1"
    end

    test "falls back to the raw title when the parser recovers none" do
      download = %{id: "d2", title: "????", media_item: nil}

      dialog = MatchDialog.open(download, :inflight)

      assert dialog.query == "????"
    end

    test "falls back to the download's media item type when the parse is unknown" do
      download = %{id: "d3", title: "1234", media_item: %{type: "tv_show"}}

      dialog = MatchDialog.open(download, :postimport)

      assert dialog.type == :tv_show
      assert dialog.mode == :postimport
    end

    test "defaults to movie when nothing indicates a type" do
      download = %{id: "d4", title: "1234", media_item: nil}

      assert MatchDialog.open(download, :inflight).type == :movie
    end

    test "tolerates an unloaded media_item association" do
      download = %{
        id: "d5",
        title: "1234",
        media_item: %Ecto.Association.NotLoaded{
          __field__: :media_item,
          __owner__: Mydia.Downloads.Download,
          __cardinality__: :one
        }
      }

      assert MatchDialog.open(download, :inflight).type == :movie
    end

    test "starts with empty results and no error" do
      download = %{id: "d6", title: "Show.Name.S01", media_item: nil}

      dialog = MatchDialog.open(download, :inflight)

      assert dialog.library_results == []
      assert dialog.external_results == []
      assert dialog.episodes == []
      assert dialog.selected == nil
      assert dialog.error == nil
      assert dialog.search_warning == nil
    end
  end

  describe "search/2" do
    setup :setup_metadata_stub

    test "returns nothing for a query under two characters" do
      dialog = MatchDialog.search(dialog_for(:movie), "a")

      assert dialog.library_results == []
      assert dialog.external_results == []
      assert dialog.search_warning == nil
    end

    test "finds a library item by title" do
      item = media_item_fixture(%{type: "movie", title: "Searchable Movie"})

      dialog = MatchDialog.search(dialog_for(:movie), "Searchable")

      assert Enum.map(dialog.library_results, & &1.id) == [item.id]
    end

    test "includes provider results alongside library results" do
      dialog = MatchDialog.search(dialog_for(:movie), "Stub")

      assert Enum.any?(dialog.external_results, &(&1.title == "Stub Movie"))
      assert dialog.search_warning == nil
    end

    test "drops a provider result whose id is already a library item" do
      _existing =
        media_item_fixture(%{
          type: "tv_show",
          title: "Stub Series",
          tvdb_id: 81_189
        })

      dialog = MatchDialog.search(dialog_for(:tv_show), "Stub")

      refute Enum.any?(dialog.external_results, &(to_string(&1.provider_id) == "81189"))
      assert Enum.any?(dialog.library_results, &(&1.title == "Stub Series"))
    end

    test "clears any prior selection and error" do
      dialog =
        %{dialog_for(:movie) | selected: %{id: "x", title: "t", type: "movie"}, error: "boom"}
        |> MatchDialog.search("Stub")

      assert dialog.selected == nil
      assert dialog.episodes == []
      assert dialog.error == nil
    end
  end

  describe "search/2 when the relay is unreachable" do
    setup :setup_metadata_stub

    setup do
      Mydia.MetadataStubProvider.fail_search()
      on_exit(&Mydia.MetadataStubProvider.clear_search_failure/0)
      :ok
    end

    test "still returns library results and warns instead of emptying the dialog" do
      item = media_item_fixture(%{type: "movie", title: "Offline Movie"})

      dialog = MatchDialog.search(dialog_for(:movie), "Offline")

      assert Enum.map(dialog.library_results, & &1.id) == [item.id]
      assert dialog.external_results == []
      assert dialog.search_warning =~ "metadata service"
    end
  end

  describe "set_type/2" do
    setup :setup_metadata_stub

    test "re-runs the search under the new type" do
      dialog =
        %MatchDialog{download_id: "d1", mode: :inflight, query: "Stub", type: :movie}
        |> MatchDialog.set_type(:tv_show)

      assert dialog.type == :tv_show
      assert Enum.any?(dialog.external_results, &(&1.media_type == :tv_show))
    end
  end

  describe "select/2" do
    import Mydia.MediaFixtures

    test "a movie submits immediately in either mode" do
      movie = media_item_fixture(%{type: "movie", title: "A Movie"})

      for mode <- [:inflight, :postimport] do
        dialog = %MatchDialog{download_id: "d1", mode: mode, type: :movie}

        assert {:submit, {id, nil}} = MatchDialog.select(dialog, movie.id)
        assert id == movie.id
      end
    end

    test "a TV show submits show-level in flight" do
      show = media_item_fixture(%{type: "tv_show", title: "A Show"})
      dialog = %MatchDialog{download_id: "d1", mode: :inflight, type: :tv_show}

      assert {:submit, {id, nil}} = MatchDialog.select(dialog, show.id)
      assert id == show.id
    end

    test "a TV show opens the episode list after import" do
      show = media_item_fixture(%{type: "tv_show", title: "A Show"})
      dialog = %MatchDialog{download_id: "d1", mode: :postimport, type: :tv_show}

      assert {:episodes, updated} = MatchDialog.select(dialog, show.id)
      assert updated.selected.id == show.id
      assert updated.selected.title == "A Show"
    end
  end

  describe "show_episodes/2 and select_episode/2" do
    import Mydia.MediaFixtures

    test "show_episodes loads the show's episodes in flight" do
      show = media_item_fixture(%{type: "tv_show", title: "A Show"})
      dialog = %MatchDialog{download_id: "d1", mode: :inflight, type: :tv_show}

      updated = MatchDialog.show_episodes(dialog, show.id)

      assert updated.selected.id == show.id
      assert is_list(updated.episodes)
    end

    test "select_episode submits the selected show and episode" do
      dialog = %MatchDialog{
        download_id: "d1",
        mode: :postimport,
        selected: %{id: "show-1", title: "A Show", type: "tv_show"}
      }

      assert MatchDialog.select_episode(dialog, "ep-1") == {:submit, {"show-1", "ep-1"}}
    end
  end

  describe "add_external/2" do
    setup :setup_metadata_stub

    import Mydia.MediaFixtures

    test "creates the media item for a provider result" do
      dialog =
        %MatchDialog{download_id: "d1", mode: :inflight, query: "Stub", type: :movie}
        |> MatchDialog.search("Stub")

      [result | _] = dialog.external_results

      assert {:added, item} = MatchDialog.add_external(dialog, result.provider_id)
      assert item.title == "Stub Movie"
      assert item.type == "movie"
      # No library_path_id is sent, so TargetResolver decides at import time.
      assert item.library_path_id == nil
    end

    test "adds a TV result through TVDB rather than TMDB" do
      dialog =
        %MatchDialog{download_id: "d1", mode: :inflight, query: "Stub", type: :tv_show}
        |> MatchDialog.search("Stub")

      [result | _] = dialog.external_results
      assert result.provider == :tvdb

      assert {:added, item} = MatchDialog.add_external(dialog, result.provider_id)
      assert item.type == "tv_show"
      assert item.tvdb_id == 81_189
    end

    test "treats an item already in the library as a plain selection" do
      _existing = media_item_fixture(%{type: "movie", title: "Unrelated", tmdb_id: 550})

      dialog =
        %MatchDialog{download_id: "d1", mode: :inflight, query: "Stub", type: :movie}
        |> MatchDialog.search("Stub")

      [result | _] = dialog.external_results

      assert {:added, item} = MatchDialog.add_external(dialog, result.provider_id)
      assert item.tmdb_id == 550
    end

    test "reports an unknown provider id as an inline error" do
      dialog =
        %MatchDialog{download_id: "d1", mode: :inflight, query: "Stub", type: :movie}
        |> MatchDialog.search("Stub")

      assert {:error, updated} = MatchDialog.add_external(dialog, "does-not-exist")
      assert updated.error =~ "no longer available"
    end
  end
end
