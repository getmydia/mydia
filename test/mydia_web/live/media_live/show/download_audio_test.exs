defmodule MydiaWeb.MediaLive.Show.DownloadAudioTest do
  # Connected LiveView tests must stay sync: the Postgres sandbox is only
  # shared with the mount process when the case is not async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Media.MediaItem

  setup %{conn: conn} do
    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "Kaiju Garden #{System.unique_integer([:positive])}"
      })

    %{conn: log_in_user(conn, admin_user_fixture()), show: show}
  end

  defp open_modal(conn, show) do
    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    view |> element("#download-audio-row") |> render_click()
    view
  end

  test "the row shows the server default until the show gets its own choice", %{
    conn: conn,
    show: show
  } do
    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    assert has_element?(view, "#download-audio-row", "Download Audio")
    assert has_element?(view, "#download-audio-row", "Server default")
    refute has_element?(view, "#download-audio-modal")

    view |> element("#download-audio-row") |> render_click()
    assert has_element?(view, "#download-audio-option-default.active")

    view |> element("#download-audio-option-en") |> render_click()

    refute has_element?(view, "#download-audio-modal")
    assert Mydia.Repo.get!(MediaItem, show.id).download_audio_language == "en"
    assert has_element?(view, "#download-audio-row", "English")
  end

  test "the stored choice is marked active", %{conn: conn, show: show} do
    {:ok, _} = Mydia.Media.update_media_item(show, %{download_audio_language: "es"})

    view = open_modal(conn, show)

    assert has_element?(view, "#download-audio-option-es.active")
    refute has_element?(view, "#download-audio-option-default.active")
  end

  test "choosing Original stores original", %{conn: conn, show: show} do
    view = open_modal(conn, show)

    view |> element("#download-audio-option-original") |> render_click()

    assert Mydia.Repo.get!(MediaItem, show.id).download_audio_language == "original"
  end

  test "the Server default option clears the choice", %{conn: conn, show: show} do
    {:ok, _} = Mydia.Media.update_media_item(show, %{download_audio_language: "en"})

    view = open_modal(conn, show)
    view |> element("#download-audio-option-default") |> render_click()

    assert Mydia.Repo.get!(MediaItem, show.id).download_audio_language == nil
    assert has_element?(view, "#download-audio-row", "Server default")
  end

  test "a malformed event leaves the stored choice untouched", %{conn: conn, show: show} do
    {:ok, _} = Mydia.Media.update_media_item(show, %{download_audio_language: "en"})
    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    render_hook(view, "set_download_audio_language", %{})

    assert Mydia.Repo.get!(MediaItem, show.id).download_audio_language == "en"
  end

  test "Cancel closes the modal without saving", %{conn: conn, show: show} do
    view = open_modal(conn, show)

    view |> element("#download-audio-modal button", "Cancel") |> render_click()

    refute has_element?(view, "#download-audio-modal")
    assert Mydia.Repo.get!(MediaItem, show.id).download_audio_language == nil
  end
end
