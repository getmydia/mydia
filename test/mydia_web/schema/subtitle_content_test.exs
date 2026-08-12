defmodule MydiaWeb.Schema.SubtitleContentTest do
  use MydiaWeb.ConnCase, async: false

  alias Mydia.AccountsFixtures
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.MediaFixtures
  alias Mydia.Repo
  alias Mydia.SettingsFixtures
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

  # `externalSubtitles` is a separate field from `subtitles` and resolves through
  # its own path, so a track that works in one can be broken in the other.
  @external_subtitles_query """
  query Movie($id: ID!) {
    movie(id: $id) {
      files {
        externalSubtitles {
          trackId
          deliverable
          content(format: VTT)
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

  defp fetch_tracks(conn, movie) do
    conn = post(conn, "/api/graphql", %{"query" => @query, "variables" => %{"id" => movie.id}})

    %{"data" => %{"movie" => %{"files" => files}}} = json_response(conn, 200)
    Enum.flat_map(files, & &1["subtitles"])
  end

  describe "an external sidecar" do
    setup %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})
      media_file = MediaFixtures.media_file_fixture(%{media_item_id: movie.id})

      dir =
        Path.join(System.tmp_dir!(), "mydia-content-test-#{System.unique_integer([:positive])}")

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

    test "returns converted VTT content", %{conn: conn, movie: movie} do
      assert [track] = fetch_tracks(conn, movie)

      assert track["deliverable"] == true
      assert String.starts_with?(track["content"], "WEBVTT")
      assert track["content"] =~ "00:00:01.000 --> 00:00:04.000"
    end

    test "returns converted content via the externalSubtitles field too", %{
      conn: conn,
      movie: movie
    } do
      conn =
        post(conn, "/api/graphql", %{
          "query" => @external_subtitles_query,
          "variables" => %{"id" => movie.id}
        })

      %{"data" => %{"movie" => %{"files" => files}}} = json_response(conn, 200)
      tracks = Enum.flat_map(files, & &1["externalSubtitles"])
      assert [track] = tracks

      assert track["deliverable"] == true
      assert String.starts_with?(track["content"], "WEBVTT")
    end
  end

  describe "an image-based track" do
    # PGS and VobSub carry bitmaps, so there is no text to deliver. The resolver
    # must answer null rather than attempting an extraction that can only fail.
    # This path never touches disk, so it needs no real media file.
    setup %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})

      metadata = %FileMetadata{
        streams: [
          %StreamInfo{
            index: 2,
            type: :subtitle,
            codec: "hdmv_pgs_subtitle",
            language: "eng",
            title: "English (PGS)"
          }
        ]
      }

      MediaFixtures.media_file_fixture(%{media_item_id: movie.id, metadata: metadata})

      {:ok, conn: log_in_user(conn, user), movie: movie}
    end

    test "is not deliverable and returns null content", %{conn: conn, movie: movie} do
      assert [track] = fetch_tracks(conn, movie)

      assert track["deliverable"] == false
      assert track["content"] == nil
    end
  end

  describe "an embedded text track" do
    # Task 2 deferred embedded-extraction coverage to this task, and this is it.
    # Every other test in the delivery chain exercises sidecars, which are read
    # straight off disk, so without this the ffmpeg extraction and its on-disk
    # cache are never executed by any test.
    setup %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      movie = MediaFixtures.media_item_fixture(%{type: "movie"})

      dir =
        Path.join(System.tmp_dir!(), "mydia-embedded-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      srt_path = Path.join(dir, "source.srt")
      File.write!(srt_path, @srt)

      relative_path = "movie.mkv"
      video_path = Path.join(dir, relative_path)

      muxed? = mux_subtitle_video(srt_path, video_path)

      library_path = SettingsFixtures.library_path_fixture(%{path: dir, type: "movies"})

      metadata = %FileMetadata{
        streams: [
          %StreamInfo{index: 0, type: :video, codec: "h264"},
          %StreamInfo{
            index: 1,
            type: :subtitle,
            codec: "subrip",
            language: "eng",
            title: "English"
          }
        ]
      }

      MediaFixtures.media_file_fixture(%{
        media_item_id: movie.id,
        library_path_id: library_path.id,
        relative_path: relative_path,
        metadata: metadata
      })

      {:ok, conn: log_in_user(conn, user), movie: movie, muxed?: muxed?}
    end

    test "is deliverable and extracts through ffmpeg", %{
      conn: conn,
      movie: movie,
      muxed?: muxed?
    } do
      assert [track] = fetch_tracks(conn, movie)

      # Deliverability is derived from the codec and holds regardless of whether
      # this machine could build the fixture.
      assert track["deliverable"] == true

      if muxed? do
        assert String.starts_with?(track["content"], "WEBVTT")
        assert track["content"] =~ "Hello there."
      end
    end
  end

  # Builds a one-second video carrying a real subtitle stream. Returns false when
  # ffmpeg is absent or refuses, so the suite still runs on a machine without it
  # rather than failing for a reason unrelated to the code under test.
  defp mux_subtitle_video(srt_path, output_path) do
    args = [
      "-v",
      "error",
      "-y",
      "-f",
      "lavfi",
      "-i",
      "color=c=black:s=64x64:d=5",
      "-i",
      srt_path,
      "-c:v",
      "libx264",
      "-pix_fmt",
      "yuv420p",
      "-c:s",
      "srt",
      output_path
    ]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_output, 0} -> File.exists?(output_path)
      {_output, _code} -> false
    end
  rescue
    _ -> false
  end
end
