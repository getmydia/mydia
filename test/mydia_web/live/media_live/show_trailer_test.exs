defmodule MydiaWeb.MediaLive.ShowTrailerTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures

  alias Mydia.Metadata.Structs.{MediaMetadata, Video}

  setup %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)
    %{conn: conn}
  end

  defp item_with_videos(videos) do
    media_item_fixture(%{
      type: "movie",
      title: "The Lantern Coast",
      metadata: %MediaMetadata{
        provider_id: "1",
        provider: :tmdb,
        media_type: :movie,
        videos: videos
      }
    })
  end

  test "the trailer modal hands every trailer to the player", %{conn: conn} do
    item =
      item_with_videos([
        %Video{key: "first", site: "YouTube", name: "Trailer", type: "Trailer"},
        %Video{key: "second", site: "YouTube", name: "Teaser", type: "Teaser"}
      ])

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    view |> element("#trailer-button") |> render_click()

    assert has_element?(view, ~s(#media-trailer-player[phx-hook="TrailerPlayer"]))
    assert has_element?(view, ~s(#media-trailer-player[data-keys='["first","second"]']))
    assert has_element?(view, ~s(#media-trailer-player[data-autoplay="true"]))
  end

  test "no trailer button without YouTube videos", %{conn: conn} do
    item = item_with_videos([%Video{key: "v", site: "Vimeo"}])

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    refute has_element?(view, "#trailer-button")
  end
end
