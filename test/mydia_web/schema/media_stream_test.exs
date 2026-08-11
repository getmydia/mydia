defmodule MydiaWeb.Schema.MediaStreamTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Library.Structs.{FileMetadata, StreamInfo}

  @query """
  query ($id: ID!) {
    movie(id: $id) {
      files {
        fileName
        container
        duration
        streams {
          index
          type
          codec
          width
          height
          frameRate
          channels
          channelLayout
          isDefault
          language
        }
      }
    }
  }
  """

  setup %{conn: conn} do
    {user, token} = create_user_and_token()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")

    %{conn: conn, user: user}
  end

  test "resolves streams from persisted metadata", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie"})

    media_file_fixture(%{
      media_item_id: movie.id,
      relative_path: "Blade Runner 2049.mkv",
      metadata: %FileMetadata{
        container: "mkv",
        duration: 9780.0,
        streams: [
          %StreamInfo{
            index: 0,
            type: :video,
            codec: "hevc",
            width: 3840,
            height: 2160,
            frame_rate: 23.976
          },
          %StreamInfo{
            index: 1,
            type: :audio,
            codec: "truehd",
            channels: 8,
            channel_layout: "7.1",
            is_default: true,
            language: "eng"
          }
        ]
      }
    })

    conn = post(conn, "/api/graphql", %{query: @query, variables: %{"id" => movie.id}})
    %{"data" => %{"movie" => %{"files" => [file]}}} = json_response(conn, 200)

    assert file["fileName"] == "Blade Runner 2049.mkv"
    assert file["container"] == "mkv"
    assert file["duration"] == 9780.0

    [video, audio] = file["streams"]
    assert video["type"] == "VIDEO"
    assert video["codec"] == "hevc"
    assert video["width"] == 3840
    assert video["frameRate"] == 23.976
    assert audio["type"] == "AUDIO"
    assert audio["channelLayout"] == "7.1"
    assert audio["isDefault"] == true
    assert audio["language"] == "eng"
  end

  test "returns null streams when capture has never run", %{conn: conn} do
    movie = media_item_fixture(%{type: "movie"})

    media_file_fixture(%{
      media_item_id: movie.id,
      relative_path: "Old Movie.mkv",
      metadata: %FileMetadata{width: 1920, height: 1080, streams: nil}
    })

    conn = post(conn, "/api/graphql", %{query: @query, variables: %{"id" => movie.id}})
    %{"data" => %{"movie" => %{"files" => [file]}}} = json_response(conn, 200)

    assert file["streams"] == nil
  end
end
