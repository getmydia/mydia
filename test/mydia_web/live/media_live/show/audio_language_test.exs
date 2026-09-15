defmodule MydiaWeb.MediaLive.Show.AudioLanguageTest do
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

  test "the row shows the server default until the show gets its own list", %{
    conn: conn,
    show: show
  } do
    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    assert has_element?(view, "#audio-language-row", "Server default")
    refute has_element?(view, "#audio-language-modal")

    view |> element("#audio-language-row") |> render_click()
    assert has_element?(view, "#audio-language-modal")

    view
    |> element("#audio-language-form")
    |> render_submit(%{"audio_languages" => %{"0" => "en", "1" => "original", "2" => ""}})

    refute has_element?(view, "#audio-language-modal")
    assert Mydia.Repo.get!(MediaItem, show.id).audio_languages == ["en", "original"]
    assert has_element?(view, "#audio-language-row", "English, Original")
  end

  test "Use server default clears the override", %{conn: conn, show: show} do
    {:ok, _} = Mydia.Media.update_media_item(show, %{audio_languages: ["en"]})
    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    view |> element("#audio-language-row") |> render_click()
    view |> element("#audio-language-reset") |> render_click()

    assert Mydia.Repo.get!(MediaItem, show.id).audio_languages == nil
    assert has_element?(view, "#audio-language-row", "Server default")
  end

  test "Cancel closes the modal without saving", %{conn: conn, show: show} do
    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    view |> element("#audio-language-row") |> render_click()
    view |> element("#audio-language-modal button", "Cancel") |> render_click()

    refute has_element?(view, "#audio-language-modal")
    assert Mydia.Repo.get!(MediaItem, show.id).audio_languages == nil
  end
end
