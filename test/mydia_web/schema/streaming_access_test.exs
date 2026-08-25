defmodule MydiaWeb.Schema.StreamingAccessTest do
  @moduledoc """
  Task 7 review findings 1 and 3: `startStreamingSession` and
  `streamingCandidates` both resolve a `MediaFile` without going through
  `Mydia.Media.get_media_item!/3` or `get_episode!/3`, so nothing enforced
  category or age restrictions on them. `startStreamingSession` is the
  actual path the Flutter player uses to start playback (see
  `player/lib/graphql/mutations/start_streaming_session.graphql`); the REST
  `HlsController.start_session/2` guarded earlier in this task is
  unreachable with a real UUID media file id and is not the production path.

  Drives requests through the real `/api/graphql` endpoint with a logged-in
  conn, the same way `subtitle_content_query_test.exs` does, so the real
  `AbsintheContext` plug populates `current_scope` exactly as it does in
  production rather than a hand-built Absinthe.run context risking a
  forgotten field.
  """

  use MydiaWeb.ConnCase, async: false

  import Ecto.Query

  alias Mydia.AccountsFixtures
  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.MediaFixtures
  alias Mydia.Repo
  alias Mydia.SettingsFixtures

  @start_streaming_session_mutation """
  mutation StartStreamingSession($fileId: ID!, $strategy: StreamingStrategy!) {
    startStreamingSession(fileId: $fileId, strategy: $strategy) {
      sessionId
    }
  }
  """

  @end_streaming_session_mutation """
  mutation EndStreamingSession($sessionId: String!) {
    endStreamingSession(sessionId: $sessionId)
  }
  """

  @streaming_candidates_query """
  query StreamingCandidates($contentType: String!, $id: ID!) {
    streamingCandidates(contentType: $contentType, id: $id) {
      fileId
    }
  }
  """

  defp restricted_movie_item do
    {:ok, item} =
      Media.create_media_item(
        Scope.system(),
        %{
          type: "movie",
          title: "Streaming Access Test Movie #{System.unique_integer([:positive])}",
          year: 2024
        },
        skip_episode_refresh: true
      )

    Repo.update_all(from(m in MediaItem, where: m.id == ^item.id), set: [category: "movie"])
    Repo.get!(MediaItem, item.id)
  end

  defp restricted_user do
    AccountsFixtures.restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})
  end

  # A real, tiny (2s) H.264+AAC file, same recipe as streaming_test.exs's
  # cold_media_file/1, so a request that slips past the authorization guard
  # actually succeeds (a real FFmpeg HLS session starts) instead of merely
  # 404ing for the unrelated reason that the file has no bytes on disk. That
  # is what makes "delete the guard, watch this test fail" meaningful here.
  defp playable_media_file(item, tmp_dir) do
    library_path = SettingsFixtures.library_path_fixture(%{path: tmp_dir, type: "movies"})
    video_path = Path.join(tmp_dir, "tiny.mp4")

    {_, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-f",
          "lavfi",
          "-i",
          "testsrc=duration=2:size=320x240:rate=10",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=1000:duration=2",
          "-c:v",
          "libx264",
          "-c:a",
          "aac",
          "-y",
          video_path
        ],
        stderr_to_stdout: true
      )

    MediaFixtures.media_file_fixture(%{
      media_item_id: item.id,
      library_path_id: library_path.id,
      relative_path: "tiny.mp4",
      size: File.stat!(video_path).size,
      analyzed_at: nil
    })
  end

  describe "startStreamingSession" do
    @tag :tmp_dir
    @tag :requires_ffmpeg
    test "denies a restricted user for a movie outside their scope", %{
      conn: conn,
      tmp_dir: tmp_dir
    } do
      item = restricted_movie_item()
      file = playable_media_file(item, tmp_dir)
      user = restricted_user()

      conn =
        post(log_in_user(conn, user), "/api/graphql", %{
          "query" => @start_streaming_session_mutation,
          "variables" => %{"fileId" => file.id, "strategy" => "TRANSCODE"}
        })

      assert %{"errors" => [%{"message" => message}], "data" => %{"startStreamingSession" => nil}} =
               json_response(conn, 200)

      # Same generic message as a file id that does not exist at all, per the
      # coordinator's instruction: a restricted account gets no signal that
      # distinguishes "off-limits" from "does not exist".
      assert message == "Failed to start streaming session"
    end

    @tag :tmp_dir
    @tag :requires_ffmpeg
    test "still starts a session for an unrestricted user", %{conn: conn, tmp_dir: tmp_dir} do
      item = restricted_movie_item()
      file = playable_media_file(item, tmp_dir)
      user = AccountsFixtures.user_fixture()

      conn =
        post(log_in_user(conn, user), "/api/graphql", %{
          "query" => @start_streaming_session_mutation,
          "variables" => %{"fileId" => file.id, "strategy" => "TRANSCODE"}
        })

      assert %{"data" => %{"startStreamingSession" => %{"sessionId" => session_id}}} =
               json_response(conn, 200)

      refute is_nil(session_id)

      stop_session(session_id, user)
    end
  end

  describe "streamingCandidates" do
    test "denies a restricted user for a file id outside their scope", %{conn: conn} do
      item = restricted_movie_item()
      file = MediaFixtures.media_file_fixture(%{media_item_id: item.id})
      user = restricted_user()

      conn =
        post(log_in_user(conn, user), "/api/graphql", %{
          "query" => @streaming_candidates_query,
          "variables" => %{"contentType" => "file", "id" => file.id}
        })

      assert %{"errors" => [%{"message" => message}], "data" => %{"streamingCandidates" => nil}} =
               json_response(conn, 200)

      assert message == "file not found"
    end

    test "still answers for an unrestricted user", %{conn: conn} do
      item = restricted_movie_item()
      file = MediaFixtures.media_file_fixture(%{media_item_id: item.id})
      user = AccountsFixtures.user_fixture()

      conn =
        post(log_in_user(conn, user), "/api/graphql", %{
          "query" => @streaming_candidates_query,
          "variables" => %{"contentType" => "file", "id" => file.id}
        })

      assert %{"data" => %{"streamingCandidates" => %{"fileId" => resolved_id}}} =
               json_response(conn, 200)

      assert resolved_id == file.id
    end
  end

  defp stop_session(session_id, user) do
    post(log_in_user(build_conn(), user), "/api/graphql", %{
      "query" => @end_streaming_session_mutation,
      "variables" => %{"sessionId" => session_id}
    })
  end
end
