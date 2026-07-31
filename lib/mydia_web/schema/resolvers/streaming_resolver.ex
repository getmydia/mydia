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

  def start_streaming_session(_parent, args, %{context: context}) do
    %{file_id: file_id, strategy: strategy} = args

    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        # Determine effective max_bitrate:
        # - For relay connections, cap at @relay_bitrate_cap regardless of request
        # - For direct connections, use player-requested value (nil means CRF default)
        max_bitrate =
          case context[:peer_connection_type] do
            "relay" ->
              min(args[:max_bitrate] || @relay_bitrate_cap, @relay_bitrate_cap)

            _ ->
              args[:max_bitrate]
          end

        start_session_for_user(file_id, user.id, strategy, max_bitrate, args[:start_position])
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
    min(position, trunc(duration) - 1)
  end

  def clamp_start_position(position, _duration), do: position

  defp start_session_for_user(file_id, user_id, strategy, max_bitrate, requested_position) do
    mode = strategy_to_mode(strategy)

    with {:ok, media_file} <- load_media_file(file_id),
         media_file <- ensure_duration_known(media_file),
         duration <- get_duration_from_metadata(media_file),
         start_position <- clamp_start_position(requested_position, duration),
         session_opts <- build_session_opts(max_bitrate, start_position),
         {:ok, pid} <-
           HlsSessionSupervisor.start_session(media_file.id, user_id, mode, session_opts),
         {:ok, info} <- HlsSession.get_info(pid) do
      Logger.info(
        "Started streaming session #{info.session_id} for file #{file_id}, user #{user_id}" <>
          if(max_bitrate, do: " (max_bitrate: #{max_bitrate}kbps)", else: "") <>
          if(start_position > 0, do: " (start_position: #{start_position}s)", else: "")
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
         start_position: start_position
       }}
    else
      {:error, reason} ->
        Logger.error("Failed to start streaming session: #{inspect(reason)}")
        {:error, "Failed to start streaming session"}
    end
  end

  defp build_session_opts(max_bitrate, start_position) do
    opts = if max_bitrate, do: [max_bitrate: max_bitrate], else: []
    if start_position > 0, do: [{:start_position, start_position} | opts], else: opts
  end

  # A never-probed file has no duration in its metadata, and the old
  # fire-and-forget `ensure_codec_info_async/1` returned before the probe wrote
  # anything, so the resolver reported `duration: nil` on every cold start. The
  # client then had nothing to compute a resume percentage against and fell back
  # to the partial HLS playlist length, which reads as 100%.
  #
  # We are about to spawn FFmpeg against this same local file, so paying for one
  # synchronous ffprobe here is cheap by comparison.
  defp ensure_duration_known(%MediaFile{analyzed_at: nil} = media_file) do
    Candidates.ensure_codec_info(media_file)
  end

  defp ensure_duration_known(media_file), do: media_file

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
