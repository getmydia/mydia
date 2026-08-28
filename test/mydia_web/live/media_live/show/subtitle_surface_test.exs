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

  test "the standalone subtitles panel is gone" do
    refute function_exported?(MydiaWeb.MediaLive.Show.Components, :subtitles_section, 1)
  end
end
