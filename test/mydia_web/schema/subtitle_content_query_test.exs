defmodule MydiaWeb.Schema.SubtitleContentQueryTest do
  use MydiaWeb.ConnCase, async: false

  alias Mydia.AccountsFixtures
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.MediaFixtures
  alias Mydia.Repo
  alias Mydia.SettingsFixtures
  alias Mydia.Subtitles.Delivery
  alias Mydia.Subtitles.Subtitle

  # The root `subtitleContent` field exists so the player can fetch exactly
  # one track's body without routing through `movie { files { subtitles {
  # content } } }`, which resolves `content` for every track of every file on
  # the title. See docs/superpowers/specs/2026-08-12-player-subtitle-download-design.md.
  @query """
  query SubtitleContent($mediaFileId: ID!, $trackId: String!) {
    subtitleContent(mediaFileId: $mediaFileId, trackId: $trackId)
  }
  """

  @srt_a """
  1
  00:00:01,000 --> 00:00:04,000
  Hello there.
  """

  @srt_b """
  1
  00:00:01,000 --> 00:00:04,000
  General Kenobi.
  """

  defp query(conn, media_file_id, track_id) do
    post(conn, "/api/graphql", %{
      "query" => @query,
      "variables" => %{"mediaFileId" => media_file_id, "trackId" => track_id}
    })
  end

  describe "an unknown track" do
    setup %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      media_file = MediaFixtures.media_file_fixture()
      {:ok, conn: log_in_user(conn, user), media_file: media_file}
    end

    test "returns nil rather than erroring", %{conn: conn, media_file: media_file} do
      conn = query(conn, media_file.id, "does-not-exist")

      assert %{"data" => %{"subtitleContent" => nil}} = json_response(conn, 200)
    end
  end

  describe "an image-based track" do
    # Deliverability is derived from the codec, so this never touches disk or
    # ffmpeg. Mirrors the equivalent case on `SubtitleTrack.content`.
    setup %{conn: conn} do
      user = AccountsFixtures.user_fixture()

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

      media_file = MediaFixtures.media_file_fixture(%{metadata: metadata})
      {:ok, conn: log_in_user(conn, user), media_file: media_file}
    end

    test "returns nil content", %{conn: conn, media_file: media_file} do
      conn = query(conn, media_file.id, "2")

      assert %{"data" => %{"subtitleContent" => nil}} = json_response(conn, 200)
    end
  end

  describe "an external sidecar" do
    setup %{conn: conn} do
      user = AccountsFixtures.user_fixture()
      media_file = MediaFixtures.media_file_fixture()

      dir =
        Path.join(
          System.tmp_dir!(),
          "mydia-subtitle-content-query-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      path = Path.join(dir, "movie.en.srt")
      File.write!(path, @srt_a)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, subtitle} =
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

      {:ok, conn: log_in_user(conn, user), media_file: media_file, subtitle: subtitle}
    end

    test "returns converted VTT content", %{conn: conn, media_file: media_file, subtitle: sub} do
      conn = query(conn, media_file.id, sub.id)

      assert %{"data" => %{"subtitleContent" => content}} = json_response(conn, 200)
      assert String.starts_with?(content, "WEBVTT")
      assert content =~ "00:00:01.000 --> 00:00:04.000"
    end
  end

  describe "an embedded media file with two text tracks" do
    # The whole point of this field: fetching track A's content must not also
    # extract track B. A resolver that walks every track on the file (the
    # defect this field replaces) writes a cache entry for both; a resolver
    # that resolves only the requested track writes one. Asserting on the
    # response body alone cannot tell these apart, since both implementations
    # return the right content for the requested track - only the cache
    # side effect distinguishes them.
    setup %{conn: conn} do
      user = AccountsFixtures.user_fixture()

      dir =
        Path.join(
          System.tmp_dir!(),
          "mydia-subtitle-content-query-embedded-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      srt_a_path = Path.join(dir, "a.srt")
      srt_b_path = Path.join(dir, "b.srt")
      File.write!(srt_a_path, @srt_a)
      File.write!(srt_b_path, @srt_b)

      relative_path = "movie.mkv"
      video_path = Path.join(dir, relative_path)

      muxed? = mux_two_subtitle_tracks(srt_a_path, srt_b_path, video_path)

      library_path = SettingsFixtures.library_path_fixture(%{path: dir, type: "movies"})

      metadata = %FileMetadata{
        streams: [
          %StreamInfo{index: 0, type: :video, codec: "h264"},
          %StreamInfo{index: 1, type: :subtitle, codec: "subrip", language: "eng", title: "A"},
          %StreamInfo{index: 2, type: :subtitle, codec: "subrip", language: "fre", title: "B"}
        ]
      }

      media_file =
        MediaFixtures.media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: relative_path,
          metadata: metadata
        })

      on_exit(fn -> File.rm_rf(Path.join(Delivery.cache_dir(), media_file.id)) end)

      {:ok, conn: log_in_user(conn, user), media_file: media_file, muxed?: muxed?}
    end

    test "resolves the requested track only", %{
      conn: conn,
      media_file: media_file,
      muxed?: muxed?
    } do
      if muxed? do
        conn = query(conn, media_file.id, "1")

        assert %{"data" => %{"subtitleContent" => content}} = json_response(conn, 200)
        assert String.starts_with?(content, "WEBVTT")
        assert content =~ "Hello there."

        cache_files =
          Delivery.cache_dir()
          |> Path.join(media_file.id)
          |> list_cache_files()

        assert Enum.any?(cache_files, &String.starts_with?(&1, "1-")),
               "expected a cache entry for the requested track (1), got: #{inspect(cache_files)}"

        refute Enum.any?(cache_files, &String.starts_with?(&1, "2-")),
               "the untouched track (2) was extracted too: #{inspect(cache_files)}"
      end
    end
  end

  defp list_cache_files(dir) do
    if File.dir?(dir), do: File.ls!(dir), else: []
  end

  # Builds a container with two real subrip subtitle streams, at indices 1 and
  # 2, distinguishable by their cue text. Returns false when ffmpeg is absent
  # or refuses, so the suite still runs on a machine without it.
  defp mux_two_subtitle_tracks(srt_a_path, srt_b_path, output_path) do
    args = [
      "-v",
      "error",
      "-y",
      "-f",
      "lavfi",
      "-i",
      "color=c=black:s=64x64:d=5",
      "-i",
      srt_a_path,
      "-i",
      srt_b_path,
      "-map",
      "0:v",
      "-map",
      "1:s",
      "-map",
      "2:s",
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
