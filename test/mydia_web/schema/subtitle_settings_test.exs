defmodule MydiaWeb.Schema.SubtitleSettingsTest do
  use MydiaWeb.ConnCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Subtitles.TrackSettings

  @query """
  query ($mediaFileId: ID!) {
    subtitleTrackSettings(mediaFileId: $mediaFileId) {
      trackRef
      offsetMs
    }
  }
  """

  @mutation """
  mutation ($mediaFileId: ID!, $trackRef: String!, $offsetMs: Int!) {
    setSubtitleOffset(mediaFileId: $mediaFileId, trackRef: $trackRef, offsetMs: $offsetMs) {
      trackRef
      offsetMs
    }
  }
  """

  setup %{conn: conn} do
    {:ok, conn: log_in_user(conn), media_file: media_file_fixture()}
  end

  test "returns an empty list when nothing is stored", %{conn: conn, media_file: media_file} do
    conn =
      post(conn, "/api/graphql", %{
        "query" => @query,
        "variables" => %{"mediaFileId" => media_file.id}
      })

    assert %{"data" => %{"subtitleTrackSettings" => []}} = json_response(conn, 200)
  end

  test "setSubtitleOffset persists and reads back", %{conn: conn, media_file: media_file} do
    conn =
      post(conn, "/api/graphql", %{
        "query" => @mutation,
        "variables" => %{"mediaFileId" => media_file.id, "trackRef" => "3", "offsetMs" => 1_500}
      })

    assert %{"data" => %{"setSubtitleOffset" => %{"trackRef" => "3", "offsetMs" => 1500}}} =
             json_response(conn, 200)

    assert TrackSettings.offset_ms(media_file.id, "3") == 1_500
  end

  test "setSubtitleOffset updates rather than duplicating", %{
    conn: conn,
    media_file: media_file
  } do
    for value <- [500, -750] do
      post(conn, "/api/graphql", %{
        "query" => @mutation,
        "variables" => %{"mediaFileId" => media_file.id, "trackRef" => "3", "offsetMs" => value}
      })
    end

    assert TrackSettings.offsets_for_media_file(media_file.id) == %{"3" => -750}
  end

  test "setSubtitleOffset rejects an out-of-range value", %{conn: conn, media_file: media_file} do
    conn =
      post(conn, "/api/graphql", %{
        "query" => @mutation,
        "variables" => %{
          "mediaFileId" => media_file.id,
          "trackRef" => "3",
          "offsetMs" => 900_000
        }
      })

    assert %{"errors" => [_ | _]} = json_response(conn, 200)
  end

  test "setSubtitleOffset returns a GraphQL error rather than crashing on a malformed mediaFileId",
       %{conn: conn} do
    conn =
      post(conn, "/api/graphql", %{
        "query" => @mutation,
        "variables" => %{"mediaFileId" => "garbage", "trackRef" => "3", "offsetMs" => 100}
      })

    assert %{"errors" => [_ | _]} = json_response(conn, 200)
  end

  test "setSubtitleOffset returns a GraphQL error rather than crashing on a well-formed but nonexistent mediaFileId",
       %{conn: conn} do
    conn =
      post(conn, "/api/graphql", %{
        "query" => @mutation,
        "variables" => %{
          "mediaFileId" => Ecto.UUID.generate(),
          "trackRef" => "3",
          "offsetMs" => 100
        }
      })

    assert %{"errors" => [_ | _]} = json_response(conn, 200)
  end

  test "subtitleTrackSettings returns an empty list rather than crashing on a malformed mediaFileId",
       %{conn: conn} do
    conn =
      post(conn, "/api/graphql", %{
        "query" => @query,
        "variables" => %{"mediaFileId" => "garbage"}
      })

    assert %{"data" => %{"subtitleTrackSettings" => []}} = json_response(conn, 200)
  end
end
