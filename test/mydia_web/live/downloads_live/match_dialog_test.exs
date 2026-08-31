defmodule MydiaWeb.DownloadsLive.MatchDialogTest do
  # async: false because later tasks in this file register a global stub
  # metadata provider through Provider.Registry, which is an Agent.
  use Mydia.DataCase, async: false

  alias MydiaWeb.DownloadsLive.MatchDialog

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
      assert dialog.adding == nil
    end
  end
end
