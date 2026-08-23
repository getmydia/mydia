defmodule MydiaWeb.Schema.MediaFileDirectPlayTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Library.Structs.FileMetadata

  # There is no `mediaFile(id:)` root query. `movie(id:)` is a root field
  # (query_types.ex:71) and `:movie` exposes `files` (media_types.ex:114), so
  # this is how a MediaFile is reached from the schema root.
  @query """
  query ($id: ID!) {
    movie(id: $id) {
      files {
        directPlaySupported
      }
    }
  }
  """

  defp encode(map), do: Base.url_encode64(Jason.encode!(map), padding: false)

  setup do
    user = user_fixture()
    movie = media_item_fixture()

    media_file_fixture(%{
      media_item_id: movie.id,
      codec: "hevc",
      audio_codec: "ac3",
      metadata: %FileMetadata{container: "mkv"}
    })

    %{user: user, movie: movie}
  end

  defp run(conn, movie, header) do
    conn =
      case header do
        nil -> conn
        value -> put_req_header(conn, "x-mydia-device-profile", value)
      end

    conn
    |> post("/api/graphql", %{"query" => @query, "variables" => %{"id" => movie.id}})
    |> json_response(200)
    |> get_in(["data", "movie", "files", Access.at(0), "directPlaySupported"])
  end

  test "returns true with no profile header, preserving pre-profile behavior", %{
    conn: conn,
    user: user,
    movie: movie
  } do
    assert run(log_in_user(conn, user), movie, nil) == true
  end

  test "returns false when the profile cannot decode the file", %{
    conn: conn,
    user: user,
    movie: movie
  } do
    header =
      encode(%{"containers" => ["mp4"], "videoCodecs" => ["h264"], "audioCodecs" => ["aac"]})

    assert run(log_in_user(conn, user), movie, header) == false
  end

  test "returns true when the profile can decode the file", %{
    conn: conn,
    user: user,
    movie: movie
  } do
    header =
      encode(%{
        "containers" => ["mkv"],
        "videoCodecs" => ["hevc"],
        "audioCodecs" => ["ac3"]
      })

    assert run(log_in_user(conn, user), movie, header) == true
  end

  test "returns true with a malformed header, since malformed means absent", %{
    conn: conn,
    user: user,
    movie: movie
  } do
    assert run(log_in_user(conn, user), movie, "not base64!!") == true
  end
end
