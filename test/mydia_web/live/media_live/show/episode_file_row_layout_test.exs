defmodule MydiaWeb.MediaLive.Show.EpisodeFileRowLayoutTest do
  @moduledoc """
  The episode file row stacks its action strip whenever the column it sits in
  is narrow, driven by a container query rather than a viewport breakpoint.

  Measured before this landed: at a 375px viewport the filename column was
  69px and showed 8 characters of a 92-character basename. At 1024px it was
  78px and showed 9, because the app drawer becomes permanent and the page
  rail widens to 20rem while the window grows by only 124px. `sm:` calls both
  of those wide, which is why the breakpoint had to go.

  These assertions are class-level and cheap. The widths themselves live in
  test/mydia_web/features/media_file_row_width_test.exs, which needs a real
  browser. See docs/superpowers/specs/2026-09-02-media-file-rows-narrow-columns-design.md.
  """
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias MydiaWeb.MediaLive.Show.SeasonComponents

  # library_path: nil rather than an unloaded association, matching
  # episode_row_test.exs: MediaFile.absolute_path/1 logs a warning per file per
  # render for the unloaded case, which would bury the real output.
  defp media_file(attrs \\ []) do
    struct!(
      %MediaFile{
        id: "file-1",
        resolution: "1080p",
        codec: "h265",
        audio_codec: "eac3",
        size: 9_876_543_210,
        library_path: nil,
        relative_path:
          "Ashvale.Hollow.S01E01.The.Salt.Lantern.2160p.WEB-DL.DDP5.1.Atmos.HDR.H.265-GROUP.mkv"
      },
      attrs
    )
  end

  defp episode(attrs \\ []) do
    struct!(
      %Episode{
        id: "ep-1",
        season_number: 1,
        episode_number: 1,
        title: "The Salt Lantern",
        monitored: true,
        air_date: ~D[2024-01-01],
        media_files: [],
        downloads: []
      },
      attrs
    )
  end

  defp render_expanded do
    render_component(&SeasonComponents.season_section/1,
      season_number: 1,
      episodes: [episode(media_files: [media_file()])],
      expanded?: true,
      expanded_episodes: MapSet.new(["ep-1"]),
      playback_enabled: true,
      segment_detection_available: false
    )
  end

  defp class_of(html, selector) do
    [class] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("class")

    class
  end

  # Matches the bare utility only, so "@lg/eprow:btn-xs" does not count as
  # "btn-xs". Without this every assertion below passes on the broken markup.
  defp has_bare?(class, utility) do
    Regex.match?(~r/(^|\s)#{Regex.escape(utility)}(\s|$)/, class)
  end

  describe "the eprow container" do
    test "is declared on the episode wrapper, which the query cannot resize" do
      class = class_of(render_expanded(), "#episode-ep-1-row")

      assert class =~ "@container/eprow"
    end
  end

  describe "the file row" do
    test "stacks by default and becomes a row only above the container threshold" do
      class = class_of(render_expanded(), "#episode-file-row-file-1")

      assert class =~ "flex-col"
      assert class =~ "@lg/eprow:flex-row"
      assert class =~ "@lg/eprow:justify-between"
    end

    test "carries no viewport breakpoint, which is the whole point" do
      html = render_expanded()

      for selector <- ~w(#episode-file-row-file-1 #episode-ep-1-detail) do
        refute class_of(html, selector) =~ "sm:",
               "#{selector} still switches on the viewport, not on its column"
      end
    end

    test "gives the action buttons a full-size tap target until the column is wide" do
      class = class_of(render_expanded(), "#subtitle-open-file-1")

      assert class =~ "@lg/eprow:btn-xs"

      refute has_bare?(class, "btn-xs"),
             "btn-xs unconditionally is a 24px target on a phone"
    end

    test "reclaims the detail indent below the threshold and restores it above" do
      class = class_of(render_expanded(), "#episode-ep-1-detail")

      assert class =~ "ml-2"
      assert class =~ "@lg/eprow:ml-8"

      refute has_bare?(class, "ml-8"),
             "a 32px indent is 8.5% of a 375px screen"
    end

    test "labels the filename with a queryable id so widths can be asserted" do
      html = render_expanded()

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#episode-file-name-file-1")
             |> Enum.any?()
    end
  end
end
