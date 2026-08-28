defmodule MydiaWeb.MediaLive.Show.SeasonSubtitlesTest do
  # async: false - opens a connected LiveView.
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Repo
  alias Mydia.Subtitles.Subtitle

  setup %{conn: conn} do
    # The app skips Oban in test (engine: false), so Oban.insert cannot be
    # resolved from the LiveView process. Start an isolated, manual-mode
    # instance so the season subtitle fetch enqueue lands where
    # assert_enqueued sees it.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    user = user_fixture()
    show = media_item_fixture(%{type: "tv_show"})
    episode = episode_fixture(%{media_item_id: show.id, season_number: 2, episode_number: 3})
    media_file = media_file_fixture(%{episode_id: episode.id})

    {:ok, conn: conn, user: user, show: show, episode: episode, media_file: media_file}
  end

  test "the season toolbar offers a subtitle fetch", ctx do
    {:ok, view, _html} =
      ctx.conn |> log_in_user(ctx.user) |> live(~p"/media/#{ctx.show.id}")

    assert has_element?(view, "#season-2-subtitles")
  end

  test "pressing it enqueues the season job", ctx do
    {:ok, view, _html} =
      ctx.conn |> log_in_user(ctx.user) |> live(~p"/media/#{ctx.show.id}")

    view |> element("#season-2-subtitles") |> render_click()

    assert_enqueued(
      worker: Mydia.Jobs.SubtitleSearch,
      args: %{mode: "season", media_item_id: ctx.show.id, season_number: 2}
    )
  end

  test "a finish broadcast for this item clears the spinner", ctx do
    {:ok, view, _html} =
      ctx.conn |> log_in_user(ctx.user) |> live(~p"/media/#{ctx.show.id}")

    view |> element("#season-2-subtitles") |> render_click()

    send(view.pid, {:subtitle_season_finished, ctx.show.id, 2})

    refute has_element?(view, "#season-2-subtitles .loading")
  end

  test "a broadcast for another media item is ignored", ctx do
    {:ok, view, _html} =
      ctx.conn |> log_in_user(ctx.user) |> live(~p"/media/#{ctx.show.id}")

    view |> element("#season-2-subtitles") |> render_click()

    send(view.pid, {:subtitle_season_finished, Ecto.UUID.generate(), 2})

    assert has_element?(view, "#season-2-subtitles .loading")
  end

  test "a finish broadcast for another season of the same item does not clear this season's spinner",
       ctx do
    # A second season so both toolbar buttons render.
    episode_fixture(%{media_item_id: ctx.show.id, season_number: 1, episode_number: 1})

    {:ok, view, _html} =
      ctx.conn |> log_in_user(ctx.user) |> live(~p"/media/#{ctx.show.id}")

    view |> element("#season-2-subtitles") |> render_click()

    # Finishing season 1 (which was never started) must not clear season 2's
    # spinner while its job is still in flight.
    send(view.pid, {:subtitle_season_finished, ctx.show.id, 1})

    assert has_element?(view, "#season-2-subtitles .loading")
  end

  test "a per-file update while the season fetch is running refreshes the open manage modal",
       ctx do
    # Mydia.Jobs.SubtitleSearch broadcasts :subtitles_updated once per file as
    # it works through the season, well before the season-level :finished
    # broadcast. If the manage modal for that file is already open, it must
    # pick up the new track without waiting for the whole season to finish.
    {:ok, view, _html} =
      ctx.conn |> log_in_user(ctx.user) |> live(~p"/media/#{ctx.show.id}")

    render_click(view, "open_subtitle_manage", %{"media-file-id" => ctx.media_file.id})

    assert has_element?(view, "#subtitle-manage-modal")
    refute render(view) =~ "subtitle-offset-form-#{ctx.media_file.id}"

    {:ok, subtitle} =
      %Subtitle{}
      |> Subtitle.changeset(%{
        media_file_id: ctx.media_file.id,
        language: "en",
        provider: "opensubtitles",
        origin: "provider",
        subtitle_hash: "season-fetch-hash",
        file_path: "/tmp/season-fetch-hash.srt",
        format: "srt"
      })
      |> Repo.insert()

    send(view.pid, {:subtitles_updated, ctx.media_file.id})

    assert has_element?(view, "#subtitle-offset-form-#{ctx.media_file.id}-#{subtitle.id}")
  end
end
