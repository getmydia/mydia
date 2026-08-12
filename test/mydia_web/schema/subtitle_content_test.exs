defmodule MydiaWeb.Schema.SubtitleContentTest do
  use MydiaWeb.ConnCase, async: false

  alias Mydia.AccountsFixtures
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.MediaFixtures
  alias Mydia.Repo
  alias Mydia.Subtitles.Subtitle

  @query """
  query Movie($id: ID!) {
    movie(id: $id) {
      files {
        subtitles {
          trackId
          format
          deliverable
          content(format: VTT)
        }
      }
    }
  }
  """

  @image_format_query """
  query Movie($id: ID!) {
    movie(id: $id) {
      files {
        subtitles {
          trackId
          content(format: PGS)
        }
      }
    }
  }
  """

  @srt """
  1
  00:00:01,000 --> 00:00:04,000
  Hello there.
  """

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture()
    movie = MediaFixtures.media_item_fixture(%{type: "movie"})
    media_file = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})

    dir = Path.join(System.tmp_dir!(), "mydia-content-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "movie.en.srt")
    File.write!(path, @srt)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _subtitle} =
      %Subtitle{}
      |> Subtitle.changeset(%{
        media_file_id: media_file.id,
        language: "en",
        format: "srt",
        subtitle_hash: "hash-#{System.unique_integer([:positive])}",
        file_path: path,
        provider: "relay"
      })
      |> Repo.insert()

    {:ok, conn: log_in_user(conn, user), movie: movie}
  end

  test "returns converted VTT content for an external sidecar", %{conn: conn, movie: movie} do
    conn =
      post(conn, "/api/graphql", %{"query" => @query, "variables" => %{"id" => movie.id}})

    %{"data" => %{"movie" => %{"files" => files}}} = json_response(conn, 200)
    tracks = files |> Enum.flat_map(& &1["subtitles"])
    assert [track] = tracks

    assert track["deliverable"] == true
    assert String.starts_with?(track["content"], "WEBVTT")
    assert track["content"] =~ "00:00:01.000 --> 00:00:04.000"
  end

  test "returns not-deliverable and nil content for an image-based embedded track", %{
    conn: conn
  } do
    movie = MediaFixtures.media_item_fixture(%{type: "movie"})

    MediaFixtures.media_file_fixture(%{
      media_item_id: movie.id,
      metadata: %FileMetadata{
        streams: [
          %StreamInfo{
            index: 2,
            type: :subtitle,
            codec: "hdmv_pgs_subtitle",
            language: "eng"
          }
        ]
      }
    })

    conn =
      post(conn, "/api/graphql", %{"query" => @query, "variables" => %{"id" => movie.id}})

    %{"data" => %{"movie" => %{"files" => files}}} = json_response(conn, 200)
    tracks = files |> Enum.flat_map(& &1["subtitles"])
    assert [track] = tracks

    assert track["deliverable"] == false
    assert track["content"] == nil
  end

  test "returns nil content rather than attempting delivery for an image output format", %{
    conn: conn,
    movie: movie
  } do
    conn =
      post(conn, "/api/graphql", %{
        "query" => @image_format_query,
        "variables" => %{"id" => movie.id}
      })

    %{"data" => %{"movie" => %{"files" => files}}} = json_response(conn, 200)
    tracks = files |> Enum.flat_map(& &1["subtitles"])
    assert [track] = tracks

    assert track["content"] == nil
  end
end
