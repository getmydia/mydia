defmodule MydiaWeb.MediaLive.Show.SubtitleModalTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath
  alias Mydia.Subtitles.Scoring
  alias MydiaWeb.MediaLive.Show.SubtitleModal

  # Production shape. The legacy `path` column is never written any more, so
  # every row carries `path: nil` and the real location is relative_path joined
  # onto the preloaded library_path.
  @subtitle_media_file %MediaFile{
    id: "mf-1",
    path: nil,
    relative_path: "The Matrix (1999)/The.Matrix.1999.1080p.BluRay.mkv",
    library_path: %LibraryPath{path: "/media/movies"}
  }

  defp subtitle_modal_html(overrides \\ []) do
    defaults = [
      media_file: @subtitle_media_file,
      subtitle_search_state: :idle,
      subtitle_search_results: [],
      subtitle_providers: [],
      downloading_subtitle_index: nil,
      selected_languages: ["en"]
    ]

    render_component(&SubtitleModal.subtitle_search_modal/1, Keyword.merge(defaults, overrides))
  end

  defp result_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        file_id: "L3N1YnRpdGxlLzM0NjczMzAtODM5MDM4OS56aXA",
        language: "en",
        format: "srt",
        subtitle_hash: "abc",
        file_name: "The.Matrix.1999.1080p.BluRay.srt",
        rating: 8.5,
        download_count: 1200,
        hearing_impaired: false,
        moviehash_match: true,
        provider_name: "OpenSubtitles",
        score: 160,
        score_breakdown: []
      },
      overrides
    )
  end

  defp loaded_html(results, overrides \\ []) do
    subtitle_modal_html(
      Keyword.merge(
        [
          subtitle_search_state: :loaded,
          subtitle_providers: [
            %{name: "OpenSubtitles", quota_remaining: nil, quota_total: nil, error: nil}
          ],
          subtitle_search_results: results
        ],
        overrides
      )
    )
  end

  defp result(attrs) do
    base = %{
      file_id: 1,
      language: "en",
      file_name: "The.Matrix.1999.1080p.BluRay.x264-AMIABLE",
      format: "srt",
      rating: nil,
      download_count: nil,
      hearing_impaired: false,
      moviehash_match: false,
      provider_name: "SubDL",
      score: 100,
      score_breakdown: []
    }

    Map.merge(base, attrs)
  end

  defp render_modal(results) do
    render_component(&SubtitleModal.subtitle_search_modal/1, %{
      media_file: %MediaFile{id: "mf-1", relative_path: "Movie.mkv", library_path: nil},
      subtitle_search_state: :loaded,
      subtitle_search_results: results,
      subtitle_providers: [
        %{name: "Mydia Relay", error: nil, quota_remaining: nil, quota_total: nil}
      ],
      downloading_subtitle_index: nil,
      selected_languages: ["en"]
    })
  end

  describe "subtitle_search_modal/1 score breakdown" do
    test "a result renders its score badge and a breakdown of its factors" do
      reference =
        Scoring.build_reference(%MediaFile{
          relative_path: "The.Matrix.1999.1080p.BluRay.x264-AMIABLE.mkv",
          library_path: nil
        })

      {score, factors} =
        Scoring.score(
          %{file_id: 1, language: "en", file_name: "The.Matrix.1999.1080p.BluRay.x264-AMIABLE"},
          %{imdb_id: "0133093"},
          reference
        )

      html = render_modal([result(%{score: score, score_breakdown: factors})])

      assert html =~ ~s(id="subtitle-score-badge-0")
      assert html =~ ~s(id="subtitle-score-breakdown-0")
      assert html =~ "Release group"
      assert html =~ "AMIABLE"
    end

    # A provider that reports no release name still renders, with every release
    # factor showing a dash rather than the row vanishing or the render raising.
    test "a result with no release name still renders its breakdown" do
      {score, factors} =
        Scoring.score(%{file_id: 1, language: "en", file_name: nil}, %{imdb_id: "0133093"}, nil)

      html = render_modal([result(%{file_name: nil, score: score, score_breakdown: factors})])

      assert html =~ ~s(id="subtitle-score-breakdown-0")
      assert html =~ "Release group"
    end
  end

  describe "subtitle_search_modal/1 shell" do
    test "names the file being searched and has no redundant footer close button" do
      html = subtitle_modal_html()

      # The header tells you which file this is for.
      assert html =~ "The.Matrix.1999.1080p.BluRay.mkv"
      # The full path is not dumped into the header text.
      refute html =~ ">/media/movies/"
      # Header X only; the footer Close button is gone.
      refute html =~ "modal-action"
      # The body is a dedicated scroll region.
      assert html =~ ~s(id="subtitle-search-body")
    end

    test "names the file from library_path + relative_path, not the dead path column" do
      html = subtitle_modal_html()

      assert html =~ "The.Matrix.1999.1080p.BluRay.mkv"
      # The tooltip still carries the resolved absolute location.
      assert html =~ ~s|title="/media/movies/The Matrix|
    end

    test "opens for a file whose library_path was not preloaded" do
      media_file = %MediaFile{
        id: "mf-2",
        path: nil,
        relative_path: "The Matrix (1999)/The.Matrix.1999.1080p.BluRay.mkv",
        library_path: %Ecto.Association.NotLoaded{
          __field__: :library_path,
          __owner__: MediaFile,
          __cardinality__: :one
        }
      }

      html = subtitle_modal_html(media_file: media_file)

      # Falls back to the relative path rather than crashing the LiveView.
      assert html =~ "The.Matrix.1999.1080p.BluRay.mkv"
    end

    test "opens for a file with no resolvable location at all" do
      media_file = %MediaFile{id: "mf-3", path: nil, relative_path: nil, library_path: nil}

      html = subtitle_modal_html(media_file: media_file)

      assert html =~ ~s(id="subtitle-search-body")
    end

    test "renders language chips as daisyUI checkbox buttons with the selection checked" do
      html = subtitle_modal_html(selected_languages: ["en", "fr"])

      assert html =~ ~s(class="filter")
      assert html =~ ~s(phx-click="clear_subtitle_languages")
      # Real checkbox inputs, not a <select multiple>.
      refute html =~ "select-bordered"
      refute html =~ "multiple"
      assert html =~ ~s(name="languages[]")
      assert html =~ ~s(aria-label="English")
      assert html =~ ~s(aria-label="Japanese")
    end

    test "promotes a selected uncommon language out of the dropdown into a chip" do
      # Finnish is not one of the eight common chips, but selecting it must not
      # bury it inside the dropdown.
      assert subtitle_modal_html(selected_languages: ["fi"]) =~ ~s(aria-label="Finnish")
    end

    test "disables search when no language is selected" do
      html = subtitle_modal_html(selected_languages: [])

      assert html =~ ~s(phx-click="perform_subtitle_search")
      assert html =~ "disabled"
    end
  end

  describe "subtitle_search_modal/1 states" do
    test "idle never claims nothing was found" do
      html = subtitle_modal_html(subtitle_search_state: :idle)

      refute html =~ "No subtitles found"
      assert html =~ "Choose one or more languages"
    end

    test "searching shows skeletons and no results" do
      html = subtitle_modal_html(subtitle_search_state: :searching)

      assert html =~ "skeleton"
      refute html =~ "No subtitles found"
    end

    test "a failed search reports the failure instead of blaming the language choice" do
      html = subtitle_modal_html(subtitle_search_state: {:error, :media_file_not_found})

      assert html =~ "alert-error"
      refute html =~ "No subtitles found"
      refute html =~ "media_file_not_found"
      assert html =~ ~s(phx-click="perform_subtitle_search")
    end

    test "with no providers configured it points at the admin page" do
      html = subtitle_modal_html(subtitle_search_state: :loaded, subtitle_providers: [])

      assert html =~ "/admin/subtitle-providers"
      refute html =~ "No subtitles found"
    end

    test "when every provider errored it names them and their reasons" do
      html =
        subtitle_modal_html(
          subtitle_search_state: :loaded,
          subtitle_providers: [
            %{
              name: "OpenSubtitles",
              quota_remaining: nil,
              quota_total: nil,
              error: "Daily quota exhausted"
            }
          ]
        )

      assert html =~ "OpenSubtitles"
      assert html =~ "Daily quota exhausted"
      refute html =~ "No subtitles found"
    end

    test "a healthy search with zero hits is the only case that says nothing was found" do
      html =
        subtitle_modal_html(
          subtitle_search_state: :loaded,
          subtitle_providers: [
            %{name: "OpenSubtitles", quota_remaining: nil, quota_total: nil, error: nil}
          ]
        )

      assert html =~ "No subtitles found"
    end

    test "a partial provider failure warns but still shows results" do
      html =
        subtitle_modal_html(
          subtitle_search_state: :loaded,
          subtitle_providers: [
            %{name: "OpenSubtitles", quota_remaining: nil, quota_total: nil, error: nil},
            %{
              name: "Podnapisi",
              quota_remaining: nil,
              quota_total: nil,
              error: "Rate limited, try again shortly"
            }
          ],
          subtitle_search_results: [
            %{
              file_id: "L3N1YnRpdGxlLzM0NjczMzAtODM5MDM4OS56aXA",
              language: "en",
              format: "srt",
              subtitle_hash: "abc",
              file_name: "The.Matrix.1999.1080p.BluRay.srt",
              rating: 8.5,
              download_count: 1200,
              hearing_impaired: false,
              moviehash_match: true,
              provider_name: "OpenSubtitles",
              score: 160,
              score_breakdown: []
            }
          ]
        )

      assert html =~ "alert-warning"
      assert html =~ "Podnapisi"
      assert html =~ "The.Matrix.1999.1080p.BluRay.srt"
    end

    test "a partial provider failure with zero results still warns about the failure" do
      html =
        subtitle_modal_html(
          subtitle_search_state: :loaded,
          subtitle_providers: [
            %{name: "OpenSubtitles", quota_remaining: nil, quota_total: nil, error: nil},
            %{
              name: "Podnapisi",
              quota_remaining: nil,
              quota_total: nil,
              error: "Rate limited, try again shortly"
            }
          ],
          subtitle_search_results: []
        )

      assert html =~ "alert-warning"
      assert html =~ "Podnapisi"
      assert html =~ "No subtitles found"
    end

    test "an unidentified file's search failure names the missing criteria, not the atom" do
      html = subtitle_modal_html(subtitle_search_state: {:error, :insufficient_search_criteria})

      assert html =~ "no hash or metadata IDs"
      refute html =~ "insufficient_search_criteria"
    end

    test "rows show the release name, a language name, and the exact-match signal" do
      html = loaded_html([result_fixture()])

      assert html =~ "list-row"
      assert html =~ "The.Matrix.1999.1080p.BluRay.srt"
      # Language name, not the raw code.
      assert html =~ "English"
      # moviehash_match is surfaced rather than discarded.
      assert html =~ "Exact match"
      assert html =~ "OpenSubtitles"
    end

    test "a row without a release name falls back to the language name" do
      html = loaded_html([result_fixture(%{file_name: nil, moviehash_match: false})])

      assert html =~ "English"
      refute html =~ "Exact match"
    end

    test "only the downloading row spins" do
      html =
        loaded_html(
          [result_fixture(), result_fixture(%{subtitle_hash: "def"})],
          downloading_subtitle_index: 0
        )

      # One spinner, not one per row.
      assert length(String.split(html, "loading-spinner")) - 1 == 1
    end

    test "the download button sends only a list index" do
      html = loaded_html([result_fixture()])

      assert html =~ ~s(phx-value-index="0")
      refute html =~ "phx-value-file-id"
      refute html =~ "phx-value-subtitle-hash"
    end

    test "hearing impaired is flagged only when true" do
      assert loaded_html([result_fixture(%{hearing_impaired: true})]) =~ "hearing impaired"
      refute loaded_html([result_fixture(%{hearing_impaired: false})]) =~ "hearing impaired"
    end
  end
end
