defmodule MydiaWeb.Features.MediaFileRowWidthTest do
  @moduledoc """
  Both media file surfaces keep a readable filename column at every width.

  The numbers this guards, all measured on the running app before the fix:

  | viewport | episode filename | movie filename |
  | -------- | ---------------- | -------------- |
  | 375      | 69px  (8 chars)  | 287px, correct |
  | 768      | 158px (19 chars) | 96px           |
  | 1024     | 78px  (9 chars)  | 16px (2 chars) |
  | 1440     | 494px            | 432px          |

  1024px is the worst case on both, not the phone: the app drawer becomes
  permanent and the page rail widens to 20rem while the window grows by 124px,
  so the content column collapses from 584px to 312px. A `sm:` variant calls
  that wide. See
  docs/superpowers/specs/2026-09-02-media-file-rows-narrow-columns-design.md.
  """
  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  # 92 characters, matching the release names this actually breaks on.
  @episode_file "/media/series/Ashvale Hollow/Season 01/" <>
                  "Ashvale.Hollow.S01E01.The.Salt.Lantern.2160p.WEB-DL.DDP5.1.Atmos.HDR.H.265-GROUP.mkv"

  @show_file "/media/series/Ashvale Hollow/" <>
               "Ashvale.Hollow.S01.COMPLETE.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-GROUP.mkv"

  # Anything under this and the label is decorative rather than readable: it is
  # roughly 25 characters of the text-sm monospace this row uses.
  @readable_px 200

  defp width_of(session, selector) do
    eval_js(
      session,
      """
      var el = document.querySelector(arguments[0]);
      if (!el) return -1;
      return Math.round(el.getBoundingClientRect().width);
      """,
      [selector]
    )
  end

  defp doc_overflows?(session) do
    eval_js(session, """
    return document.documentElement.scrollWidth >
           document.documentElement.clientWidth + 1;
    """)
  end

  setup do
    show = insert(:tv_show, title: "Ashvale Hollow")
    episode = insert(:episode, media_item: show, season_number: 1, episode_number: 1)

    insert(:media_file,
      episode: episode,
      path: @episode_file,
      resolution: "2160p",
      codec: "h265"
    )

    # episode: nil makes this a show-level file, which is what
    # media_files_section/1 renders. It is the same component the movie page
    # uses, so it exercises the mfrow container without needing a movie.
    show_file =
      insert(:media_file,
        episode: nil,
        media_item: show,
        path: @show_file,
        resolution: "2160p",
        codec: "h265"
      )

    %{show: show, episode: episode, show_file: show_file}
  end

  describe "the episode file row" do
    @tag :feature
    test "keeps a readable filename at every width", ctx do
      %{session: session, show: show, episode: episode} = ctx

      login_as_admin(session)

      for {w, h} <- [
            {375, 812},
            {414, 896},
            {640, 960},
            {768, 1024},
            {900, 900},
            {1024, 768},
            {1280, 800},
            {1440, 900}
          ] do
        session
        |> resize_window(w, h)
        |> visit("/media/#{show.id}")
        |> wait_for_liveview()

        js_click(session, ~s([aria-controls="episode-#{episode.id}-detail"]))

        assert Wallaby.Browser.has_css?(session, "#episode-#{episode.id}-detail")

        width = width_of(session, "[id^='episode-file-name-']")

        assert width >= @readable_px,
               "at #{w}px the episode filename column was #{width}px, " <>
                 "which is below the #{@readable_px}px readable floor"
      end
    end
  end

  describe "the Media Files card" do
    @tag :feature
    test "keeps a readable filename at every width", ctx do
      %{session: session, show: show, show_file: show_file} = ctx

      login_as_admin(session)

      for {w, h} <- [
            {375, 812},
            {414, 896},
            {640, 960},
            {768, 1024},
            {900, 900},
            {1024, 768},
            {1280, 800},
            {1440, 900}
          ] do
        session
        |> resize_window(w, h)
        |> visit("/media/#{show.id}")
        |> wait_for_liveview()

        assert Wallaby.Browser.has_css?(session, "#version-#{show_file.id}")

        width = width_of(session, "#file-name-#{show_file.id}")

        assert width >= @readable_px,
               "at #{w}px the Media Files filename column was #{width}px, " <>
                 "which is below the #{@readable_px}px readable floor"
      end
    end
  end

  describe "the episode row toolbar" do
    @tag :feature
    test "does not push the document sideways at 1024px", ctx do
      %{session: session, show: show} = ctx

      login_as_admin(session)

      session
      |> resize_window(1024, 768)
      |> visit("/media/#{show.id}")
      |> wait_for_liveview()

      assert Wallaby.Browser.has_css?(session, "[id^='episode-'][id$='-row']")

      refute doc_overflows?(session),
             "the episode row toolbar overflowed the viewport, which is the " <>
               "50px of horizontal scroll this fix removed"
    end
  end
end
