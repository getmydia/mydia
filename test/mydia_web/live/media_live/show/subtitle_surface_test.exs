defmodule MydiaWeb.MediaLive.Show.SubtitleSurfaceTest do
  # async: false - opens a connected LiveView, which shares the Postgres
  # sandbox connection with the test process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  describe "a file with no subtitle tracks" do
    setup do
      user = user_fixture()
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 3})
      # `file` is a reserved ExUnit context key, hence `media_file` here.
      media_file = media_file_fixture(%{episode_id: episode.id})

      {:ok, user: user, show: show, episode: episode, media_file: media_file}
    end

    test "still offers the manage button on its row", ctx do
      {:ok, view, _html} =
        ctx.conn
        |> log_in_user(ctx.user)
        |> live(~p"/media/#{ctx.show.id}")

      # Season 2 is the show's only season, so Helpers.default_expanded_seasons/2
      # (the newest-season fallback) already expands it on mount -- toggling it
      # here would collapse it instead. Only the episode needs an explicit
      # expand to reveal its file row.
      render_click(view, "toggle_episode_expanded", %{"episode-id" => ctx.episode.id})

      assert has_element?(view, "#subtitle-open-#{ctx.media_file.id}")
    end

    test "opens the manage modal and offers search, upload and rescan", ctx do
      {:ok, view, _html} =
        ctx.conn
        |> log_in_user(ctx.user)
        |> live(~p"/media/#{ctx.show.id}")

      render_click(view, "open_subtitle_manage", %{"media-file-id" => ctx.media_file.id})

      assert has_element?(view, "#subtitle-manage-modal")
      assert has_element?(view, "#subtitle-manage-search")
      assert has_element?(view, "#subtitle-manage-upload")
      assert has_element?(view, "#subtitle-manage-rescan")
    end

    test "reaches the upload form from the manage modal", ctx do
      {:ok, view, _html} =
        ctx.conn
        |> log_in_user(ctx.user)
        |> live(~p"/media/#{ctx.show.id}")

      render_click(view, "open_subtitle_manage", %{"media-file-id" => ctx.media_file.id})
      view |> element("#subtitle-manage-upload") |> render_click()

      assert has_element?(view, "#subtitle-upload-modal")
      assert has_element?(view, "#subtitle-upload-form")
    end

    test "reaches the search modal from the manage modal", ctx do
      {:ok, view, _html} =
        ctx.conn
        |> log_in_user(ctx.user)
        |> live(~p"/media/#{ctx.show.id}")

      render_click(view, "open_subtitle_manage", %{"media-file-id" => ctx.media_file.id})
      view |> element("#subtitle-manage-search") |> render_click()

      assert has_element?(view, "#subtitle-search-modal")
    end
  end

  describe "a TV file attached directly to the show, with no episode" do
    # media_item_id set, episode_id nil: Mydia.Jobs.MediaImport's catch-all
    # fallback creates exactly this shape when a TV download's episode can't
    # be resolved, and Mydia.Media.RecentlyAdded's moduledoc documents these
    # as expected "unmatched files". season_components.ex only ever iterates
    # episode.media_files, so a file like this renders under no episode row
    # -- media_files_section/1 (the flat "Media Files" card, which
    # Loaders.build_preload_list/0 populates for every item type via
    # media_item.media_files) is its only route to a subtitle affordance.
    # This is the regression test for gating media_files_section/1's
    # subtitle controls behind `media_item.type != "tv_show"`: with that
    # gate in place this file has no subtitle affordance anywhere on the
    # page, breaking the branch's hard requirement that every file, however
    # it's attached, can still reach search, upload and download.
    setup do
      user = user_fixture()
      show = media_item_fixture(%{type: "tv_show"})
      # `file` is a reserved ExUnit context key, hence `media_file` here.
      media_file = media_file_fixture(%{media_item_id: show.id})

      {:ok, user: user, show: show, media_file: media_file}
    end

    test "has a subtitle button in the flat Media Files list and can open the manage modal",
         ctx do
      {:ok, view, _html} =
        ctx.conn
        |> log_in_user(ctx.user)
        |> live(~p"/media/#{ctx.show.id}")

      # No expand needed: media_files_section/1 always renders, unlike
      # episode_file_row/1 which only appears once an episode is expanded --
      # and this file belongs to no episode at all.
      assert has_element?(view, "#subtitle-open-file-#{ctx.media_file.id}")

      render_click(view, "open_subtitle_manage", %{"media-file-id" => ctx.media_file.id})

      assert has_element?(view, "#subtitle-manage-modal")
    end
  end

  describe "a TV episode's file is rendered by exactly one surface" do
    setup do
      user = user_fixture()
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 3})
      media_file = media_file_fixture(%{episode_id: episode.id})

      {:ok, user: user, show: show, episode: episode, media_file: media_file}
    end

    # media_files_section/1 used to merge episode files in via
    # all_media_files/1, so this file rendered twice on one page: once under
    # its episode and once in the flat card, unlabelled. The two renders were
    # kept apart only by a DOM-id suffix. They are now disjoint by
    # construction -- the card filters to files with no episode_id -- which is
    # a stronger guarantee than distinct ids, so this asserts the split
    # directly.
    test "the flat Media Files card leaves it to the episode row", ctx do
      {:ok, view, _html} =
        ctx.conn
        |> log_in_user(ctx.user)
        |> live(~p"/media/#{ctx.show.id}")

      refute has_element?(view, "#media-files-section")
      refute has_element?(view, "#subtitle-open-file-#{ctx.media_file.id}")

      render_click(view, "toggle_episode_expanded", %{"episode-id" => ctx.episode.id})

      assert has_element?(view, "#subtitle-open-#{ctx.media_file.id}")
      refute has_element?(view, "#subtitle-open-file-#{ctx.media_file.id}")
    end
  end

  test "the standalone subtitles panel is gone" do
    refute function_exported?(MydiaWeb.MediaLive.Show.Components, :subtitles_section, 1)
  end
end
