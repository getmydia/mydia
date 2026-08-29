defmodule MydiaWeb.MediaLive.Show.ModalsTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.MediaLive.Show.Modals
  alias Mydia.Library.MediaFile
  alias Mydia.Metadata.Structs.SearchResult
  alias Mydia.Settings.LibraryPath

  defp candidate(id, title, year) do
    %SearchResult{
      provider_id: to_string(id),
      provider: :metadata_relay,
      media_type: :tv_show,
      title: title,
      year: year
    }
  end

  describe "file_details_modal/1 HDR badge" do
    defp hdr_file(overrides) do
      Map.merge(
        %MediaFile{
          id: "mf-hdr",
          relative_path: "Movie (2020)/movie.mkv",
          library_path: %LibraryPath{path: "/movies"},
          resolution: "2160p",
          size: 1_500_000_000,
          codec: "hevc",
          audio_codec: "eac3",
          hdr_format: nil,
          dolby_vision_profile: nil,
          dolby_vision_bl_compat_id: nil
        },
        overrides
      )
    end

    test "renders the Hdr.display/1 text, not the raw enum atom" do
      # Guards against rendering @file_details.hdr_format directly, which
      # would show the raw Ecto.Enum atom ("hdr10") in the admin UI instead
      # of the display string ("HDR10") Mydia.Library.Hdr.display/1 produces.
      html =
        render_component(&Modals.file_details_modal/1,
          file_details: hdr_file(%{hdr_format: :hdr10})
        )

      assert html =~ "HDR10"
      refute html =~ ">hdr10<"
    end

    test "a Dolby Vision profile 8 file shows Dolby Vision plus the profile number" do
      html =
        render_component(&Modals.file_details_modal/1,
          file_details:
            hdr_file(%{hdr_format: :hdr10, dolby_vision_profile: 8, dolby_vision_bl_compat_id: 1})
        )

      assert html =~ "Dolby Vision"
      assert html =~ "Profile 8"
    end

    test "a Dolby Vision profile 5 file (hdr_format nil by design) still shows the badge" do
      # Profile 5 has no HDR10-compatible base layer, so hdr_format is nil.
      # Gating the badge on hdr_format alone would hide it for the most
      # premium HDR format there is.
      html =
        render_component(&Modals.file_details_modal/1,
          file_details:
            hdr_file(%{hdr_format: nil, dolby_vision_profile: 5, dolby_vision_bl_compat_id: 0})
        )

      assert html =~ "badge-accent"
      assert html =~ "Dolby Vision"
      assert html =~ "Profile 5"
    end

    test "a genuinely SDR file (no base, no DV profile) shows None" do
      html =
        render_component(&Modals.file_details_modal/1,
          file_details: hdr_file(%{hdr_format: nil, dolby_vision_profile: nil})
        )

      refute html =~ "badge-accent"
      assert html =~ "None"
    end
  end

  describe "file_details_modal/1 file path" do
    test "names an orphaned file instead of rendering a blank path" do
      orphaned = %MediaFile{
        id: "mf-orphan",
        path: nil,
        relative_path: nil,
        library_path: nil,
        resolution: nil,
        codec: nil,
        audio_codec: nil,
        size: nil
      }

      html = render_component(&Modals.file_details_modal/1, file_details: orphaned)

      assert html =~ "Unknown file"
    end

    test "renders the absolute path of a resolvable file" do
      resolvable = %MediaFile{
        id: "mf-ok",
        path: nil,
        relative_path: "Movie (2020)/movie.mkv",
        library_path: %LibraryPath{path: "/movies"},
        resolution: "1080p",
        codec: "hevc",
        audio_codec: "eac3",
        size: 1_000
      }

      html = render_component(&Modals.file_details_modal/1, file_details: resolvable)

      assert html =~ "/movies/Movie (2020)/movie.mkv"
    end
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

  describe "quality_profile_modal/1" do
    test "lists every profile plus the default choice, marking the active one" do
      profile_a = %Mydia.Settings.QualityProfile{id: "profile-a", name: "Profile A"}
      profile_b = %Mydia.Settings.QualityProfile{id: "profile-b", name: "Profile B"}

      html =
        render_component(&Modals.quality_profile_modal/1,
          media_item: %Mydia.Media.MediaItem{quality_profile_id: "profile-b"},
          quality_profiles: [profile_a, profile_b],
          default_quality_profile_name: "House Default"
        )

      assert html =~ "Profile A"
      assert html =~ "Profile B"
      assert html =~ "Use default (House Default)"
      assert html =~ ~s(phx-value-profile-id="profile-b")
      assert html =~ ~s(phx-click="hide_quality_profile_modal")
    end
  end

  describe "target_library_modal/1" do
    test "lists Automatic plus every candidate library, marking the active one" do
      library = %LibraryPath{id: "lib-a", path: "/media/movies-a"}

      html =
        render_component(&Modals.target_library_modal/1,
          media_item: %Mydia.Media.MediaItem{library_path_id: "lib-a"},
          libraries: [library]
        )

      assert html =~ "Automatic"
      assert html =~ "movies-a"
      assert html =~ ~s(phx-value-library-path-id="lib-a")
      assert html =~ ~s(phx-click="hide_target_library_modal")
    end
  end

  describe "add_to_collection_modal/1" do
    test "with no collections, offers a create-collection link instead of a list" do
      html =
        render_component(&Modals.add_to_collection_modal/1,
          media_item: %Mydia.Media.MediaItem{},
          user_collections: [],
          item_collections: []
        )

      assert html =~ "No collections yet"
      assert html =~ "Create Collection"
      refute html =~ ~s(phx-click="add_to_collection")
    end

    test "lists collections and marks the ones the item already belongs to" do
      in_collection = %Mydia.Collections.Collection{id: "c-1", name: "In It", is_system: false}
      not_in_collection = %Mydia.Collections.Collection{id: "c-2", name: "Not In It"}

      html =
        render_component(&Modals.add_to_collection_modal/1,
          media_item: %Mydia.Media.MediaItem{},
          user_collections: [in_collection, not_in_collection],
          item_collections: [in_collection]
        )

      assert html =~ "In It"
      assert html =~ "Not In It"
      assert html =~ ~s(phx-click="remove_from_collection")
      assert html =~ ~s(phx-value-collection-id="c-1")
      assert html =~ ~s(phx-click="add_to_collection")
      assert html =~ ~s(phx-value-collection-id="c-2")
    end
  end
end
