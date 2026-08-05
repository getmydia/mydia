defmodule MydiaWeb.Schema.Resolvers.StreamingResolver do
  @moduledoc """
  Resolvers for streaming session management GraphQL mutations.

  These mutations allow P2P clients to start and end HLS streaming sessions
  via GraphQL instead of HTTP endpoints.
  """

  require Logger

  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Streaming.Candidates
  alias Mydia.Streaming.FfmpegHlsTranscoder
  alias Mydia.Streaming.HlsSessionSupervisor
  alias Mydia.Streaming.HlsSession

  @doc """
  Returns streaming candidates for a media item.

  This allows P2P clients to determine the optimal streaming strategy
  before initiating playback.
  """
  @spec streaming_candidates(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def streaming_candidates(_parent, %{content_type: content_type, id: id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      _user ->
        case Candidates.resolve_media_file(content_type, id) do
          {:ok, media_file} ->
            media_file = Candidates.ensure_codec_info(media_file)
            candidates = Candidates.build_streaming_candidates(media_file)
            metadata = Candidates.build_metadata_response(media_file)

            # For relay connections, only allow TRANSCODE (direct play won't work
            # within relay bandwidth limits)
            candidates =
              if context[:peer_connection_type] == "relay" do
                Enum.filter(candidates, fn c -> c.strategy == "TRANSCODE" end)
              else
                candidates
              end

            # Convert string strategies to atoms for the GraphQL enum
            candidates =
              Enum.map(candidates, fn candidate ->
                %{candidate | strategy: strategy_to_atom(candidate.strategy)}
              end)

            {:ok, %{file_id: media_file.id, candidates: candidates, metadata: metadata}}

          {:error, :not_found} ->
            {:error, "#{content_type} not found"}

          {:error, :no_media_files} ->
            {:error, "No media files available"}

          {:error, :invalid_content_type} ->
            {:error, "Invalid content type. Use 'movie', 'episode', or 'file'"}
        end
    end
  end

  defp strategy_to_atom("DIRECT_PLAY"), do: :direct_play
  defp strategy_to_atom("REMUX"), do: :remux
  defp strategy_to_atom("HLS_COPY"), do: :hls_copy
  defp strategy_to_atom("TRANSCODE"), do: :transcode
  defp strategy_to_atom(other), do: String.downcase(other) |> String.to_existing_atom()

  @doc """
  Starts an HLS streaming session for a media file.

  Returns the session ID and media duration for the client to use.
  """
  @spec start_streaming_session(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  @relay_bitrate_cap 2000
  # A 2000kbps ceiling cannot carry 1080p at watchable quality, so the height
  # ceiling that accompanies it is 720p. The two move together: raising one
  # without the other produces either wasted pixels or wasted bits.
  @relay_height_cap 720

  def start_streaming_session(_parent, args, %{context: context}) do
    %{file_id: file_id, strategy: strategy} = args

    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        {max_bitrate, clamped_height} =
          effective_quality(
            context[:peer_connection_type],
            args[:max_bitrate],
            args[:max_height]
          )

        # Composed here, not left to the transcoder, so the height this
        # mutation echoes back is the one that will actually be encoded.
        # The operator's ceiling used to be applied inside the transcoder
        # alone, which made a server with a ceiling set report "Original" to
        # a client that asked for no cap while really scaling it — the one
        # thing echoing the applied value exists to prevent.
        max_height = FfmpegHlsTranscoder.effective_max_height(clamped_height)

        start_session_for_user(
          file_id,
          user.id,
          strategy,
          max_bitrate,
          max_height,
          args[:start_position]
        )
    end
  end

  @doc """
  Ends an HLS streaming session.

  This stops the FFmpeg transcoder and cleans up server-side resources.
  """
  @spec end_streaming_session(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def end_streaming_session(_parent, %{session_id: session_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      _user ->
        terminate_session(session_id)
    end
  end

  # Private functions

  @doc false
  # Public for unit testing. Keeps the requested offset inside the media so a
  # corrupted client-side progress value cannot start FFmpeg past the end,
  # which would yield an empty playlist and look identical to the resume bug
  # this whole change exists to fix.
  def clamp_start_position(nil, _duration), do: 0

  def clamp_start_position(position, _duration) when position <= 0, do: 0

  def clamp_start_position(position, duration) when is_number(duration) and duration > 0 do
    max(0, min(position, trunc(duration) - 1))
  end

  def clamp_start_position(position, _duration), do: position

  @doc false
  # Public for unit testing. Resolves what the server will actually apply,
  # which is not always what the client asked for.
  #
  # A relay connection carries media through Mydia's own infrastructure, so
  # its ceiling is not negotiable by the client: an uncapped request becomes
  # capped, and an over-cap request is lowered. A direct connection is
  # peer-to-peer or local, so the client's choice stands.
  def effective_quality("relay", requested_bitrate, requested_height) do
    {min(requested_bitrate || @relay_bitrate_cap, @relay_bitrate_cap),
     min(requested_height || @relay_height_cap, @relay_height_cap)}
  end

  def effective_quality(_connection_type, requested_bitrate, requested_height) do
    {requested_bitrate, requested_height}
  end

  defp start_session_for_user(
         file_id,
         user_id,
         strategy,
         max_bitrate,
         max_height,
         requested_position
       ) do
    mode = strategy_to_mode(strategy)

    with {:ok, media_file} <- load_media_file(file_id),
         media_file <- ensure_duration_known(media_file),
         duration <- get_duration_from_metadata(media_file),
         start_position <- clamp_start_position(requested_position, duration),
         session_opts <- build_session_opts(max_bitrate, max_height, start_position),
         {:ok, pid} <-
           HlsSessionSupervisor.start_session(media_file.id, user_id, mode, session_opts),
         {:ok, info} <- HlsSession.get_info(pid) do
      # Report the offset the session is actually transcoding from, not the
      # one this request clamped: start_session/4 may have reused a running
      # session or adopted a concurrent winner, either of which can be running
      # from a different offset than this caller asked for.
      session_start_position = info.start_position

      Logger.info(
        "Started streaming session #{info.session_id} for file #{file_id}, user #{user_id}" <>
          if(max_bitrate, do: " (max_bitrate: #{max_bitrate}kbps)", else: "") <>
          if(session_start_position > 0,
            do: " (start_position: #{session_start_position}s)",
            else: ""
          )
      )

      content_id = resolve_content_id(media_file)
      Mydia.Integrations.Trakt.Scrobbler.scrobble_start(user_id, content_id)

      if content_id != [] do
        Mydia.Events.playback_event("started", user_id, content_id, %{"origin" => "player"})
      end

      {:ok,
       %{
         session_id: info.session_id,
         duration: duration,
         start_position: session_start_position,
         max_bitrate: max_bitrate,
         max_height: max_height
       }}
    else
      {:error, reason} ->
        Logger.error("Failed to start streaming session: #{inspect(reason)}")
        {:error, "Failed to start streaming session"}
    end
  end

  defp build_session_opts(max_bitrate, max_height, start_position) do
    opts = if max_bitrate, do: [max_bitrate: max_bitrate], else: []
    opts = if max_height, do: [{:max_height, max_height} | opts], else: opts
    if start_position > 0, do: [{:start_position, start_position} | opts], else: opts
  end

  # A never-probed file has no duration in its metadata, and the old
  # fire-and-forget `Candidates.ensure_codec_info_async/1` (since deleted —
  # this was its last caller) returned before the probe wrote anything, so the
  # resolver reported `duration: nil` on every cold start. The client then had
  # nothing to compute a resume percentage against and fell back to the
  # partial HLS playlist length, which reads as 100%.
  #
  # Probing inline is what makes resume correct on a file's very first play.
  # But ffprobe is itself bounded by :ffprobe_timeout_ms (30s by default)
  # precisely because library paths can sit on slow network mounts, and
  # blocking the play request for that long reads to a user as a hang.
  #
  # Cap the inline wait far below that. A fast local probe — the common case —
  # still lands and resume is correct immediately. A slow one falls back to the
  # old behaviour of no duration now, with the probe still running to populate
  # metadata for the next play, instead of stalling playback.
  @inline_probe_budget_ms 3_000

  @doc false
  # Public for unit testing, same as clamp_start_position/2: the budget_ms
  # argument only exists so a test can force the fallback branch with a
  # budget of 0 instead of mutating the global :ffprobe_timeout_ms env (which
  # has previously caused SQLite/Postgres concurrency leaks in this repo).
  def ensure_duration_known(media_file, budget_ms \\ @inline_probe_budget_ms)

  def ensure_duration_known(%MediaFile{analyzed_at: nil} = media_file, budget_ms) do
    task =
      Task.Supervisor.async_nolink(Mydia.TaskSupervisor, fn ->
        Candidates.ensure_codec_info(media_file)
      end)

    # `Task.ignore/1` on timeout, rather than a bare `Task.yield/2`: the reply
    # and the monitor stay live otherwise, so `{ref, result}` and
    # `{:DOWN, ...}` land in this process's mailbox minutes later. A GraphQL
    # resolver over an Absinthe/Phoenix channel runs in a long-lived process,
    # so those would accumulate. `Task.ignore/1` discards the reply without
    # stopping the task, which is exactly the intent below.
    case Task.yield(task, budget_ms) || Task.ignore(task) do
      {:ok, %MediaFile{} = probed} ->
        probed

      _ ->
        # Deliberately not shutting the task down: it finishes in the
        # background and writes the metadata, so the next play has a duration.
        Logger.info(
          "ffprobe exceeded the #{budget_ms}ms inline budget for file " <>
            "#{media_file.id}; starting the session without a known duration"
        )

        media_file
    end
  end

  def ensure_duration_known(media_file, _budget_ms), do: media_file

  defp load_media_file(file_id) do
    {:ok, Library.get_media_file!(file_id, preload: [:library_path])}
  rescue
    Ecto.NoResultsError ->
      {:error, :not_found}
  end

  defp strategy_to_mode(:hls_copy), do: :copy
  defp strategy_to_mode(:transcode), do: :transcode
  defp strategy_to_mode(_), do: :transcode

  defp get_duration_from_metadata(%{metadata: %{duration: duration}})
       when is_number(duration) do
    duration
  end

  defp get_duration_from_metadata(_), do: nil

  defp terminate_session(session_id) do
    # Look up session by session_id in the registry
    registry_key = {:session, session_id}

    case Registry.lookup(Mydia.Streaming.HlsSessionRegistry, registry_key) do
      [{pid, _meta}] ->
        # Stop the session
        HlsSession.stop(pid)
        Logger.info("Terminated streaming session #{session_id}")
        {:ok, true}

      [] ->
        # Session not found, but that's okay (may have already timed out)
        Logger.debug("Session #{session_id} not found, may have already terminated")
        {:ok, true}
    end
  end

  defp resolve_content_id(media_file) do
    cond do
      media_file.episode_id -> [episode_id: media_file.episode_id]
      media_file.media_item_id -> [media_item_id: media_file.media_item_id]
      true -> []
    end
  end
end
