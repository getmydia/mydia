defmodule MydiaWeb.MediaLive.Show.ModalsTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.MediaLive.Show.Modals
  alias Mydia.Metadata.Structs.SearchResult

  defp candidate(id, title, year) do
    %SearchResult{
      provider_id: to_string(id),
      provider: :metadata_relay,
      media_type: :tv_show,
      title: title,
      year: year
    }
  end

  describe "reidentify_modal/1" do
    test "renders candidates with selectable buttons wired to the select event" do
      html =
        render_component(&Modals.reidentify_modal/1,
          provider: :tmdb,
          candidates: [candidate(1396, "Ghost in the Shell", 2002)]
        )

      assert html =~ "Re-identify on TMDB"
      assert html =~ "Ghost in the Shell"
      assert html =~ "2002"
      assert html =~ ~s(phx-click="select_reidentify_candidate")
      assert html =~ ~s(phx-value-provider_id="1396")
      # Warns about the destructive consequence.
      assert html =~ "resets episode-level watch history"
    end

    test "renders an empty state when there are no candidates" do
      html =
        render_component(&Modals.reidentify_modal/1, provider: :tmdb, candidates: [])

      assert html =~ "No results found on TMDB"
      refute html =~ ~s(phx-click="select_reidentify_candidate")
    end

    test "always offers a cancel action" do
      html =
        render_component(&Modals.reidentify_modal/1, provider: :tvdb, candidates: [])

      assert html =~ ~s(phx-click="cancel_reidentify")
      assert html =~ "Re-identify on TheTVDB"
    end
  end

  describe "file_delete_confirm_modal/1" do
    defp file_to_delete do
      %Mydia.Library.MediaFile{
        relative_path: "Movie (2020)/movie.mkv",
        size: 1_500_000_000,
        library_path: %Mydia.Settings.LibraryPath{path: "/movies"}
      }
    end

    test "defaults to deleting the file from disk" do
      html =
        render_component(&Modals.file_delete_confirm_modal/1,
          file_to_delete: file_to_delete(),
          delete_file_from_disk: true
        )

      # The "delete from disk" radio is pre-selected.
      assert html =~ ~r/value="true"[^>]*checked/
      refute html =~ ~r/value="false"[^>]*checked/
      # Button reflects the destructive choice.
      assert html =~ "Delete File"
      assert html =~ ~s(phx-change="toggle_file_delete_from_disk")
      # The old, now-inaccurate copy is gone.
      refute html =~ "will remain on disk"
    end

    test "reflects the keep-on-disk choice when toggled off" do
      html =
        render_component(&Modals.file_delete_confirm_modal/1,
          file_to_delete: file_to_delete(),
          delete_file_from_disk: false
        )

      assert html =~ ~r/value="false"[^>]*checked/
      refute html =~ ~r/value="true"[^>]*checked/
      assert html =~ "Remove from Library"
    end
  end

  describe "manual_search_modal/1 row states" do
    defp modal_html(result_extra) do
      result =
        Map.merge(
          %Mydia.Indexers.SearchResult{
            title: "Some.Movie.2020.1080p",
            download_url: "magnet:?xt=urn:btih:" <> String.duplicate("e", 40),
            indexer: "test-indexer",
            size: 1_000,
            seeders: 12,
            leechers: 3,
            quality: nil
          }
          |> Map.put(:stream_position, 0),
          result_extra
        )

      render_component(&Modals.manual_search_modal/1,
        manual_search_context: %{type: :media_item},
        media_item: %Mydia.Media.MediaItem{title: "Some Movie", type: "movie"},
        manual_search_query: "Some Movie 2020",
        searching: false,
        results_empty?: false,
        indexer_errors: [],
        streams: %{search_results: [{"search-result-00000-1", result}]},
        quality_filter: nil,
        min_seeders: 0,
        sort_by: :seeders,
        close_after_grab: false
      )
    end

    test "grab_failed renders a retry button with the reason" do
      html = modal_html(%{grab_failed: "No download clients are configured"})

      assert html =~ "Failed — retry"
      assert html =~ "No download clients are configured"
      assert html =~ ~s(phx-click="download_from_search")
    end

    test "duplicate renders a disabled already-downloading button" do
      html = modal_html(%{duplicate: true})

      assert html =~ "Already downloading"
    end

    test "downloading renders the grabbing spinner state" do
      html = modal_html(%{downloading: true})

      assert html =~ "Grabbing…"
    end
  end
end
