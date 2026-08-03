defmodule MydiaWeb.Live.Components.LibrarySearchFormTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata
  alias MydiaWeb.Live.Components.LibrarySearchForm

  defp media_item(metadata) do
    %MediaItem{
      id: "a3f1c9e2-0000-4000-8000-000000000001",
      title: "The Matrix",
      type: "movie",
      year: 1999,
      metadata: metadata
    }
  end

  defp render_form(results) do
    render_component(&LibrarySearchForm.library_search_form/1,
      search_results: results,
      on_search: "search_library",
      on_select: "select_library_item",
      download_id: "dl-1"
    )
  end

  describe "library_search_form/1" do
    test "renders the poster of an item whose metadata is a MediaMetadata struct" do
      # MediaItem.metadata is a Mydia.Media.MetadataType, so a persisted item
      # always loads as a %MediaMetadata{} — a struct that does not implement
      # Access. Reading it with get_in/bracket syntax raised
      # UndefinedFunctionError (MediaMetadata.fetch/2) and took the whole
      # Issues tab down with it.
      metadata = %MediaMetadata{
        provider_id: "603",
        provider: :metadata_relay,
        media_type: :movie,
        poster_path: "/matrix-poster.jpg"
      }

      html = render_form([media_item(metadata)])

      assert html =~ "The Matrix"
      assert html =~ "matrix-poster.jpg"
    end

    test "falls back to the placeholder when the struct carries no poster" do
      metadata = %MediaMetadata{
        provider_id: "603",
        provider: :metadata_relay,
        media_type: :movie,
        poster_path: nil
      }

      html = render_form([media_item(metadata)])

      assert html =~ "The Matrix"
      assert html =~ "hero-film"
    end

    test "renders an item with no metadata at all" do
      html = render_form([media_item(nil)])

      assert html =~ "The Matrix"
      assert html =~ "hero-film"
    end
  end
end
