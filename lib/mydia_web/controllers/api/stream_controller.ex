defmodule MydiaWeb.Api.StreamController do
  use MydiaWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Mydia.Library.FileRanking
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Repo

  alias Mydia.Streaming.{
    AudioPreferences,
    Candidates,
    Compatibility,
    DeviceProfile,
    FfmpegRemuxer,
    HlsSession,
    HlsSessionSupervisor,
    DirectPlaySession
  }

  alias MydiaWeb.Api.RangeHelper

  require Logger

  @doc """
  Stream a movie by media_item_id.

  Automatically selects the best quality media file available.
  """
  def stream_movie(conn, %{"id" => media_item_id}) do
    try do
      media_item =
        Mydia.Media.get_media_item!(media_item_id, preload: [media_files: active_files_query()])

      # Highest resolution, then bitrate. See Mydia.Library.FileRanking.
      case FileRanking.best(media_item.media_files) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "No media files available for this movie"})

        media_file ->
          stream_media_file(conn, media_file)
      end
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Movie not found"})
    end
  end

  @doc """
  Stream an episode by episode_id.

  Automatically selects the best quality media file available.
  """
  def stream_episode(conn, %{"id" => episode_id}) do
    try do
      episode =
        Mydia.Media.get_episode!(episode_id, preload: [media_files: active_files_query()])

      # Highest resolution, then bitrate. See Mydia.Library.FileRanking.
      case FileRanking.best(episode.media_files) do
        nil ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "No media files available for this episode"})

        media_file ->
          stream_media_file(conn, media_file)
      end
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Episode not found"})
    end
  end

  @doc """
  Unified streaming endpoint that intelligently routes to the optimal streaming method.

  Routes to:
  - Direct play (HTTP Range requests) for browser-compatible files
  - HLS transcoding for incompatible files (when implemented)

  Supports:
  - Full file download (no Range header)
  - Partial content delivery (HTTP 206)
  - Seeking via Range requests
  """
  def stream(conn, %{"id" => media_file_id}) do
    # Load media file with preloads to check access. A trashed file is not a
    # streaming candidate — see the comment on active_files_query/0 below.
    try do
      media_file =
        from(mf in MediaFile,
          where: is_nil(mf.trashed_at),
          # `episode: :media_item` rather than a bare `:episode`: a TV
          # media_file has a null media_item_id and reaches its show only
          # through the episode, so the flat preload leaves
          # AudioTrackSelector with no original language and silently drops
          # the "original" audio preference for the whole TV library on this
          # path while the HLS path honours it.
          preload: [:media_item, :library_path, episode: :media_item]
        )
        |> Repo.get!(media_file_id)

      stream_media_file(conn, media_file)
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media file not found"})
    end
  end

  @doc """
  Returns a prioritized list of streaming candidates for a media file.

  The client should iterate through the candidates using browser APIs
  (MediaCapabilities, MediaSource.isTypeSupported, canPlayType) to find
  the first supported option, then use that strategy when calling the
  stream endpoint.

  ## Parameters

  - content_type: "movie" or "episode"
  - id: The media item ID or episode ID

  ## Response

  Returns JSON with candidates array and metadata:

      {
        "candidates": [
          {
            "strategy": "DIRECT_PLAY",
            "mime": "video/mp4; codecs=\"avc1.640028, mp4a.40.2\"",
            "container": "mp4",
            "video_codec": "avc1.640028",
            "audio_codec": "mp4a.40.2"
          },
          ...
        ],
        "metadata": {
          "duration": 596.5,
          "width": 1920,
          "height": 1080,
          "bitrate": 5000000
        }
      }
  """
  def candidates(conn, %{"content_type" => content_type, "id" => id}) do
    case Candidates.resolve_media_file(content_type, id) do
      {:ok, media_file} ->
        media_file = Candidates.ensure_codec_info(media_file)

        candidates =
          Candidates.build_streaming_candidates(
            media_file,
            conn.assigns[:device_profile] || DeviceProfile.browser_default()
          )

        # Carries the viewer through, so this endpoint's
        # preferred_audio_languages reflects a stored per-show choice the same
        # way the GraphQL resolver's does. Without it a web client doing
        # direct play gets the config-only list while the Flutter client gets
        # the personalised one, from the same server, for the same file.
        metadata =
          case get_user_id(conn) do
            {:ok, user_id} -> Candidates.build_metadata_response(media_file, user_id: user_id)
            _ -> Candidates.build_metadata_response(media_file)
          end

        json(conn, %{
          candidates: candidates,
          metadata: metadata
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "#{content_type} not found"})

      {:error, :no_media_files} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No media files available"})

      {:error, :invalid_content_type} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid content type. Use 'movie', 'episode', or 'file'"})
    end
  end

  # Mirrors the filter in Mydia.Streaming.Candidates: a trashed file is not a
  # streaming candidate. Without this, ranking would reliably surface a trashed
  # high-resolution file where the unordered head only did so sometimes.
  defp active_files_query do
    from(mf in MediaFile, where: is_nil(mf.trashed_at), preload: :library_path)
  end

  # Main streaming function that handles a media file
  defp stream_media_file(conn, media_file) do
    Logger.info(
      "Streaming media_file id=#{media_file.id}, codec=#{inspect(media_file.codec)}, " <>
        "audio_codec=#{inspect(media_file.audio_codec)}, container=#{inspect(media_file.metadata && media_file.metadata.container)}"
    )

    # Resolve absolute path from relative path and library_path
    case MediaFile.absolute_path(media_file) do
      nil ->
        Logger.error("Cannot resolve path for media_file #{media_file.id}: missing library_path")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Media file path cannot be resolved"})

      absolute_path ->
        # Verify file exists on disk
        if File.exists?(absolute_path) do
          # If codec info is missing, try to extract it on-the-fly
          media_file = Candidates.ensure_codec_info(media_file)
          route_stream(conn, media_file, absolute_path)
        else
          Logger.warning(
            "Media file #{media_file.id} not found at resolved path: #{absolute_path}"
          )

          conn
          |> put_status(:not_found)
          |> json(%{error: "Media file not found on disk"})
        end
    end
  end

  # Routes to appropriate streaming method based on client-selected strategy
  # or falls back to auto-detection for backward compatibility
  defp route_stream(conn, media_file, absolute_path) do
    # Check if client specified a strategy (new candidates-based approach)
    strategy = conn.query_params["strategy"]

    if strategy do
      # Client has explicitly selected a strategy via candidates API
      route_with_strategy(conn, media_file, absolute_path, strategy)
    else
      # Fallback to legacy auto-detection (for backward compatibility)
      route_with_auto_detection(conn, media_file, absolute_path)
    end
  end

  # Route based on client-selected strategy from candidates API
  defp route_with_strategy(conn, media_file, absolute_path, strategy) do
    Logger.info(
      "Streaming #{absolute_path} with client-selected strategy: #{strategy} (codec: #{media_file.codec}/#{media_file.audio_codec})"
    )

    case strategy do
      "DIRECT_PLAY" ->
        stream_file_direct(conn, media_file, absolute_path)

      "REMUX" ->
        stream_file_remux(conn, media_file, absolute_path)

      "HLS_COPY" ->
        reason = "Client selected HLS with stream copy"
        start_hls_session(conn, media_file, reason, :copy)

      "TRANSCODE" ->
        reason = "Client selected transcoding"
        start_hls_session(conn, media_file, reason, :transcode)

      _ ->
        Logger.warning("Unknown strategy: #{strategy}, falling back to auto-detection")
        route_with_auto_detection(conn, media_file, absolute_path)
    end
  end

  # Legacy auto-detection based on compatibility check (for backward compatibility)
  # New clients should use the candidates API with explicit strategy parameter
  defp route_with_auto_detection(conn, media_file, absolute_path) do
    compatibility = Compatibility.check_compatibility(media_file)

    Logger.info("Auto-detecting stream method for #{absolute_path}: #{compatibility}")

    case compatibility do
      :direct_play ->
        Logger.info(
          "Streaming #{absolute_path} via direct play (compatible: #{media_file.codec}/#{media_file.audio_codec})"
        )

        stream_file_direct(conn, media_file, absolute_path)

      :needs_remux ->
        # Default to remux - modern browsers support fMP4
        reason = Compatibility.remux_reason(media_file)

        Logger.info(
          "Streaming #{absolute_path} via fMP4 remux: #{reason} (codec: #{media_file.codec}/#{media_file.audio_codec})"
        )

        stream_file_remux(conn, media_file, absolute_path)

      :needs_transcoding ->
        # Default to transcoding for incompatible codecs
        reason = Compatibility.transcoding_reason(media_file)

        Logger.info(
          "File #{absolute_path} needs transcoding: #{reason} (codec: #{media_file.codec}, audio: #{media_file.audio_codec})"
        )

        start_hls_session(conn, media_file, reason, :transcode)
    end
  end

  defp start_hls_session(conn, media_file, reason, hls_mode) do
    case get_user_id(conn) do
      {:ok, user_id} ->
        Logger.info(
          "Starting HLS session for media_file_id=#{media_file.id}, user_id=#{user_id}, mode=#{hls_mode}"
        )

        session_opts = AudioPreferences.session_opts(user_id, media_file)

        case HlsSessionSupervisor.start_session(media_file.id, user_id, hls_mode, session_opts) do
          {:ok, _pid} ->
            # Get session info to retrieve session_id
            case HlsSessionSupervisor.get_session(media_file.id, user_id) do
              {:ok, session_pid} ->
                case HlsSession.get_info(session_pid) do
                  {:ok, session_info} ->
                    # Construct master playlist URL with mode query param
                    # mode=copy means stream copy (no re-encoding), mode=transcode means actual transcoding
                    master_playlist_path =
                      ~p"/api/v1/hls/#{session_info.session_id}/index.m3u8?mode=#{hls_mode}"

                    Logger.info(
                      "HLS session started (#{hls_mode}), master playlist: #{master_playlist_path}"
                    )

                    # Check if client wants JSON response instead of redirect
                    # Web browsers can't reliably follow redirects with fetch API
                    if conn.query_params["resolve"] == "json" do
                      # Return the HLS URL as JSON for web clients
                      # Include duration so player can show correct total time
                      # (HLS live playlists don't include total duration)
                      duration =
                        (media_file.metadata || FileMetadata.empty()).duration

                      json(conn, %{hls_url: master_playlist_path, duration: duration})
                    else
                      # Redirect to master playlist (native clients)
                      conn
                      |> put_resp_header("location", master_playlist_path)
                      |> send_resp(302, "")
                    end

                  {:error, error} ->
                    Logger.error("Failed to get session info: #{inspect(error)}")

                    conn
                    |> put_status(:internal_server_error)
                    |> json(%{error: "Failed to start transcoding session"})
                end

              {:error, error} ->
                Logger.error("Failed to retrieve session: #{inspect(error)}")

                conn
                |> put_status(:internal_server_error)
                |> json(%{error: "Failed to start transcoding session"})
            end

          {:error, :media_file_not_found} ->
            Logger.error("Media file #{media_file.id} not found for HLS session")

            conn
            |> put_status(:not_found)
            |> json(%{error: "Media file not found"})

          {:error, {:pipeline_start_failed, pipeline_error}} ->
            Logger.error("HLS pipeline failed to start: #{inspect(pipeline_error)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{
              error: "Transcoding failed to start",
              reason: reason,
              details:
                "The transcoding pipeline failed to initialize. MKV files with certain codecs may not be supported yet."
            })

          {:error, error} ->
            Logger.error("Failed to start HLS session: #{inspect(error)}")

            conn
            |> put_status(:internal_server_error)
            |> json(%{
              error: "Transcoding required but failed to start",
              reason: reason,
              details: "Unable to start transcoding session. Please try again later."
            })
        end

      {:error, :no_user} ->
        Logger.warning("HLS transcoding requested but no authenticated user")

        conn
        |> put_status(:unauthorized)
        |> json(%{
          error: "Authentication required for transcoding",
          reason: reason
        })
    end
  end

  defp get_user_id(conn) do
    case Mydia.Auth.Guardian.Plug.current_resource(conn) do
      nil -> {:error, :no_user}
      user -> {:ok, user.id}
    end
  end

  defp stream_file_direct(conn, media_file, file_path) when conn.method != "HEAD" do
    # Start tracking direct play session if user is authenticated
    case get_user_id(conn) do
      {:ok, user_id} ->
        case HlsSessionSupervisor.start_direct_session(media_file.id, user_id) do
          {:ok, pid, _status} ->
            DirectPlaySession.heartbeat(pid)

          error ->
            Logger.warning("Failed to start direct play session tracker: #{inspect(error)}")
        end

      _ ->
        :ok
    end

    file_stat = File.stat!(file_path)
    file_size = file_stat.size

    # Get MIME type from file extension
    mime_type = RangeHelper.get_mime_type(file_path)

    # Parse Range header if present
    range_header = get_req_header(conn, "range") |> List.first()

    case RangeHelper.parse_range_header(range_header, file_size) do
      {:ok, start, end_pos} ->
        # Partial content response (206)
        {offset, length} = RangeHelper.calculate_range(start, end_pos)
        content_range = RangeHelper.format_content_range(start, end_pos, file_size)

        conn
        |> put_status(:partial_content)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-type", mime_type)
        |> put_resp_header("content-range", content_range)
        |> put_resp_header("content-length", to_string(length))
        |> put_resp_header("x-streaming-mode", "direct")
        |> send_file(:partial_content, file_path, offset, length)

      :error when is_nil(range_header) ->
        # No range header - send full file (200)
        conn
        |> put_status(:ok)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-type", mime_type)
        |> put_resp_header("content-length", to_string(file_size))
        |> put_resp_header("x-streaming-mode", "direct")
        |> send_file(:ok, file_path)

      :error ->
        # Invalid range header - return 416 Range Not Satisfiable
        conn
        |> put_status(:requested_range_not_satisfiable)
        |> put_resp_header("content-range", "bytes */#{file_size}")
        |> json(%{error: "Invalid range request"})
    end
  end

  # Stream file via fMP4 remuxing (for files with compatible codecs but incompatible container)
  defp stream_file_remux(conn, _media_file, _file_path) when conn.method == "HEAD" do
    # For HEAD requests, just return headers without starting the remux process
    # This allows clients to detect the streaming mode without triggering FFmpeg
    conn
    |> put_resp_content_type("video/mp4")
    |> put_resp_header("x-streaming-mode", "remux")
    |> send_resp(200, "")
  end

  defp stream_file_remux(conn, media_file, file_path) do
    # Get duration - first try metadata, then probe fresh from file
    duration = get_duration_for_remux(media_file, file_path)

    Logger.info("Starting remux for #{file_path} with duration: #{inspect(duration)}")

    # Same per-show language the HLS path applies. Without it a viewer who
    # picked English on one episode gets the operator default on the next
    # whenever the client happens to choose REMUX, which is precisely the
    # stickiness this is meant to provide.
    remux_opts =
      [duration: duration, media_file: media_file] ++
        case get_user_id(conn) do
          {:ok, user_id} -> AudioPreferences.session_opts(user_id, media_file)
          _ -> []
        end

    case FfmpegRemuxer.start_remux(file_path, remux_opts) do
      {:ok, port, os_pid} ->
        # Stream the remuxed content to the client
        FfmpegRemuxer.stream_to_conn(conn, port, os_pid)

      {:error, :ffmpeg_not_found} ->
        Logger.error("FFmpeg not found on system, cannot remux #{file_path}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Streaming not available", details: "FFmpeg is not installed"})

      {:error, reason} ->
        Logger.error("Failed to start remux for #{file_path}: #{inspect(reason)}")

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to start streaming"})
    end
  end

  # Get duration for remuxing - try metadata first, then probe fresh
  defp get_duration_for_remux(media_file, file_path) do
    case (media_file.metadata || FileMetadata.empty()).duration do
      duration when is_number(duration) and duration > 0 ->
        duration

      _ ->
        # Probe fresh from file
        case Mydia.Library.ThumbnailGenerator.get_duration(file_path) do
          {:ok, duration} when duration > 0 ->
            Logger.info("Probed fresh duration: #{duration}s")
            duration

          _ ->
            nil
        end
    end
  end
end
