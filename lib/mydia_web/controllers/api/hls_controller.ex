defmodule MydiaWeb.Api.HlsController do
  use MydiaWeb, :controller

  require Logger

  alias Mydia.Streaming.{HlsSessionSupervisor, HlsSession}

  @doc """
  Serves the HLS master playlist for a session.

  The session_id is provided in the URL path and the user_id comes from
  the authenticated user (conn.assigns.current_user).
  """
  def master_playlist(conn, %{"session_id" => session_id}) do
    with {:ok, user_id} <- get_user_id(conn),
         {:ok, pid} <- find_session_by_id(session_id, user_id) do
      # Try cached path first, then discover
      file_path =
        case HlsSession.get_playlist_path(pid) do
          {:ok, nil} ->
            # No cached path - discover it
            {:ok, info} = HlsSession.get_info(pid)
            temp_dir = info.temp_dir

            # Try index.m3u8 first (new format), then playlist.m3u8 (FFmpeg default/old sessions)
            index_path = Path.join(temp_dir, "index.m3u8")
            playlist_path = Path.join(temp_dir, "playlist.m3u8")

            path =
              cond do
                File.exists?(index_path) -> index_path
                File.exists?(playlist_path) -> playlist_path
                true -> nil
              end

            # Cache the discovered path
            if path, do: HlsSession.cache_playlist_path(pid, path)

            path

          {:ok, cached_path} ->
            # Use cached path if it still exists
            if File.exists?(cached_path) do
              cached_path
            else
              # Cached path no longer valid, clear it and rediscover
              HlsSession.cache_playlist_path(pid, nil)
              {:ok, info} = HlsSession.get_info(pid)
              temp_dir = info.temp_dir
              index_path = Path.join(temp_dir, "index.m3u8")
              playlist_path = Path.join(temp_dir, "playlist.m3u8")

              path =
                cond do
                  File.exists?(index_path) -> index_path
                  File.exists?(playlist_path) -> playlist_path
                  true -> nil
                end

              if path, do: HlsSession.cache_playlist_path(pid, path)
              path
            end
        end

      case file_path do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Master playlist not ready yet, please retry"})

        path ->
          case File.read(path) do
            {:ok, content} ->
              # Update session activity
              heartbeat_session(session_id, user_id)

              conn
              |> put_resp_content_type("application/vnd.apple.mpegurl")
              |> put_resp_header("cache-control", "no-cache")
              |> send_resp(200, content)

            {:error, reason} ->
              Logger.error("Error reading playlist #{path}: #{inspect(reason)}")

              conn
              |> put_status(:internal_server_error)
              |> json(%{error: "Failed to serve master playlist"})
          end
      end
    else
      {:error, :no_user} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})

      {:error, :session_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "HLS session not found"})

      {:error, reason} ->
        Logger.error("Error serving master playlist: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to serve master playlist"})
    end
  end

  @doc """
  Serves variant playlists (quality-specific playlists).

  Path format: /api/v1/hls/:session_id/:track_id/index.m3u8
  """
  def variant_playlist(conn, %{"session_id" => session_id, "track_id" => track_id}) do
    with {:ok, user_id} <- get_user_id(conn),
         {:ok, temp_dir} <- get_session_temp_dir(session_id, user_id),
         playlist_path <- Path.join([temp_dir, track_id, "index.m3u8"]),
         {:ok, content} <- File.read(playlist_path) do
      # Update session activity
      heartbeat_session(session_id, user_id)

      conn
      |> put_resp_content_type("application/vnd.apple.mpegurl")
      |> put_resp_header("cache-control", "no-cache")
      |> send_resp(200, content)
    else
      {:error, :no_user} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})

      {:error, :session_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "HLS session not found"})

      {:error, :enoent} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Variant playlist not found"})

      {:error, reason} ->
        Logger.error("Error serving variant playlist: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to serve variant playlist"})
    end
  end

  @doc """
  Serves HLS segment files.

  Path format: /api/v1/hls/:session_id/:track_id/:segment

  Supports both Membrane (track subdirectories) and FFmpeg (flat structure) backends.
  """
  def segment(conn, %{"session_id" => session_id, "track_id" => track_id, "segment" => segment}) do
    with {:ok, user_id} <- get_user_id(conn),
         {:ok, temp_dir} <- get_session_temp_dir(session_id, user_id) do
      # Try Membrane-style path first (track subdirectory)
      membrane_path = Path.join([temp_dir, track_id, segment])

      # Fall back to FFmpeg-style path (root directory) if track doesn't exist
      ffmpeg_path = Path.join(temp_dir, segment)

      segment_path =
        cond do
          File.exists?(membrane_path) -> membrane_path
          File.exists?(ffmpeg_path) -> ffmpeg_path
          true -> nil
        end

      case segment_path do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Segment not found"})

        path ->
          # Update session activity
          heartbeat_session(session_id, user_id)

          # Serve the segment file
          conn
          |> put_resp_content_type(get_segment_mime_type(segment))
          |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
          |> send_file(200, path)
      end
    else
      {:error, :no_user} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})

      {:error, :session_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "HLS session not found"})
    end
  end

  @doc """
  Serves HLS segments from the root directory (FFmpeg backend).

  Path format: /api/v1/hls/:session_id/:segment

  This route handles FFmpeg's flat structure where segments are in the root directory.
  """
  def root_segment(conn, %{"session_id" => session_id, "segment" => segment}) do
    with {:ok, user_id} <- get_user_id(conn),
         {:ok, temp_dir} <- get_session_temp_dir(session_id, user_id),
         segment_path <- Path.join(temp_dir, segment),
         true <- File.exists?(segment_path) do
      # Update session activity
      heartbeat_session(session_id, user_id)

      # Serve the segment file
      conn
      |> put_resp_content_type(get_segment_mime_type(segment))
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_file(200, segment_path)
    else
      {:error, :no_user} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})

      {:error, :session_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "HLS session not found"})

      false ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Segment not found"})
    end
  end

  @doc """
  Terminates an HLS session.

  This endpoint stops the transcoding session, terminates the FFmpeg process,
  and cleans up temporary files.

  DELETE /api/v1/hls/:session_id
  """
  def terminate_session(conn, %{"session_id" => session_id}) do
    with {:ok, user_id} <- get_user_id(conn),
         {:ok, pid} <- find_session_by_id(session_id, user_id) do
      Logger.info("Terminating HLS session #{session_id} for user #{user_id}")
      HlsSession.stop(pid)

      conn
      |> put_status(:ok)
      |> json(%{status: "terminated", session_id: session_id})
    else
      {:error, :no_user} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})

      {:error, :session_not_found} ->
        # Session not found is OK - it might have already terminated
        conn
        |> put_status(:ok)
        |> json(%{status: "not_found", session_id: session_id})
    end
  end

  @doc """
  Initiates an HLS session for a media file.

  This endpoint starts a new HLS transcoding session (or returns an existing one)
  and returns the master playlist URL.

  POST /api/v1/hls/start
  Body: {"media_file_id": 123}
  """
  def start_session(conn, %{"media_file_id" => media_file_id}) do
    with {:ok, user_id} <- get_user_id(conn),
         {media_file_id, ""} <- Integer.parse(to_string(media_file_id)),
         {:ok, _pid} <- HlsSessionSupervisor.start_session(media_file_id, user_id),
         {:ok, session_info} <- get_session_info(media_file_id, user_id) do
      # Construct master playlist URL
      master_playlist_url = url(~p"/api/v1/hls/#{session_info.session_id}/index.m3u8")

      conn
      |> put_status(:ok)
      |> json(%{
        session_id: session_info.session_id,
        master_playlist_url: master_playlist_url,
        status: "ready"
      })
    else
      {:error, :no_user} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Authentication required"})

      {:error, :media_file_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media file not found"})

      {:error, {:pipeline_start_failed, reason}} ->
        Logger.error("Failed to start HLS pipeline: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to start transcoding session"})

      {:error, reason} ->
        Logger.error("Error starting HLS session: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to start HLS session"})

      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid media_file_id"})
    end
  end

  ## Private Helpers

  defp get_user_id(conn) do
    case Mydia.Auth.Guardian.Plug.current_resource(conn) do
      nil -> {:error, :no_user}
      user -> {:ok, user.id}
    end
  end

  defp get_session_temp_dir(session_id, user_id) do
    # For now, we'll derive the media_file_id from the session lookup
    # In a real implementation, you might want to store this mapping differently
    case find_session_by_id(session_id, user_id) do
      {:ok, pid} ->
        case HlsSession.get_info(pid) do
          {:ok, info} -> {:ok, info.temp_dir}
          error -> error
        end

      error ->
        error
    end
  end

  defp find_session_by_id(session_id, _user_id) do
    # O(1) lookup using Registry
    case Registry.lookup(Mydia.Streaming.HlsSessionRegistry, {:session, session_id}) do
      [{pid, _meta}] -> {:ok, pid}
      [] -> {:error, :session_not_found}
    end
  end

  defp get_session_info(media_file_id, user_id) do
    case HlsSessionSupervisor.get_session(media_file_id, user_id) do
      {:ok, pid} -> HlsSession.get_info(pid)
      error -> error
    end
  end

  defp heartbeat_session(session_id, user_id) do
    case find_session_by_id(session_id, user_id) do
      {:ok, pid} ->
        HlsSession.heartbeat(pid)
        :ok

      _ ->
        :ok
    end
  end

  defp get_segment_mime_type(segment) do
    cond do
      String.ends_with?(segment, ".m4s") -> "video/iso.segment"
      String.ends_with?(segment, ".mp4") -> "video/mp4"
      String.ends_with?(segment, ".ts") -> "video/mp2t"
      true -> "application/octet-stream"
    end
  end
end
