defmodule MydiaWeb.MediaLive.Show.StreamLinkTest do
  # Connected LiveView tests cannot be async under the PostgreSQL sandbox.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.Factory

  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias MydiaWeb.MediaLive.Show.SeasonComponents
  alias MydiaWeb.StreamLink

  defp verified(href) do
    ["", "stream", token, _name] = String.split(href, "/")
    StreamLink.verify(token)
  end

  defp href_of(html, selector) do
    [href] =
      html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute("href")

    href
  end

  describe "movie page" do
    setup %{conn: conn} do
      {conn, user} = register_and_log_in_user(conn)
      library_path = insert(:library_path)
      item = insert(:media_item, %{type: "movie", title: "Zephyr Station", year: 2030})

      file =
        insert(:media_file, %{
          media_item_id: item.id,
          episode: nil,
          library_path_id: library_path.id,
          relative_path: "Zephyr Station (2030)/Zephyr.Station.2030.1080p.mkv"
        })

      %{conn: conn, user: user, item: item, media_file: file}
    end

    test "movie rows leave the link to the file details modal", %{
      conn: conn,
      item: item,
      media_file: file
    } do
      {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

      refute has_element?(view, "#stream-link-#{file.id}")
    end

    test "the file details modal shows the link and a copy button", %{
      conn: conn,
      user: user,
      item: item,
      media_file: file
    } do
      {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")
      render_click(view, "show_file_details", %{"file-id" => file.id})

      assert has_element?(view, "#file-details-copy-stream-link")
      href = href_of(render(view), "#file-details-stream-link")
      assert verified(href) == {:ok, {user.id, file.id}}
    end
  end

  test "the episode file row links to its stream" do
    user_id = Ecto.UUID.generate()
    file_id = Ecto.UUID.generate()

    file = %MediaFile{
      id: file_id,
      resolution: "1080p",
      library_path: nil,
      relative_path: "Ashvale.Hollow.S01E01.1080p.mkv"
    }

    episode = %Episode{
      id: "ep-1",
      season_number: 1,
      episode_number: 1,
      title: "The Salt Lantern",
      monitored: true,
      air_date: ~D[2024-01-01],
      media_files: [file],
      downloads: []
    }

    html =
      render_component(&SeasonComponents.season_section/1,
        season_number: 1,
        episodes: [episode],
        expanded?: true,
        expanded_episodes: MapSet.new(["ep-1"]),
        player_enabled: false,
        segment_detection_available: false,
        current_user_id: user_id
      )

    assert verified(href_of(html, "#stream-link-#{file_id}")) == {:ok, {user_id, file_id}}
  end
end
