defmodule MydiaWeb.Schema.Resolvers.StreamingResolver do
  @moduledoc """
  Resolvers for streaming session management GraphQL mutations.

  These mutations allow P2P clients to start and end HLS streaming sessions
  via GraphQL instead of HTTP endpoints.
  """

  require Logger

  alias Mydia.Library
  alias Mydia.Streaming.Candidates
  alias Mydia.Streaming.HlsSessionSupervisor
  alias Mydia.Streaming.HlsSession
  alias Mydia.Streaming.Torrent.CandidateCache

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

  @doc """
  Returns torrent candidates for instant streaming.
  """
  def torrent_candidates(_parent, %{content_type: content_type, id: id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        result =
          case MydiaWeb.Schema.Resolvers.NodeId.decode(id) do
            {:tmdb, tmdb_id} ->
              Mydia.Streaming.Torrent.Candidates.list_candidates_by_external_id(
                content_type,
                "tmdb",
                tmdb_id
              )

            {:tmdb_episode, tmdb_id, season, episode} ->
              Mydia.Streaming.Torrent.Candidates.list_candidates_by_external_id(
                content_type,
                "tmdb",
                tmdb_id,
                season: season,
                episode: episode
              )

            {:tvdb, tvdb_id} ->
              Mydia.Streaming.Torrent.Candidates.list_candidates_by_external_id(
                content_type,
                "tvdb",
                tvdb_id
              )

            {:tvdb_episode, tvdb_id, season, episode} ->
              Mydia.Streaming.Torrent.Candidates.list_candidates_by_external_id(
                content_type,
                "tvdb",
                tvdb_id,
                season: season,
                episode: episode
              )

            _ ->
              Mydia.Streaming.Torrent.Candidates.list_candidates(content_type, id)
          end

        # Remember the magnets we returned to this user so startTorrentSession
        # can refuse magnets we didn't surface ourselves. This is the interim
        # guard for the candidate-id-based hardening; the long-term plan is
        # to return opaque server-issued candidate ids.
        case result do
          {:ok, candidates} ->
            magnets =
              candidates
              |> Enum.map(fn c -> Map.get(c, :magnet_link) end)
              |> Enum.reject(&is_nil/1)

            CandidateCache.remember(user.id, magnets)

            {:ok, candidates}

          other ->
            other
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

        start_session_for_user(file_id, user.id, strategy, max_bitrate)
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

  @doc """
  Starts a torrent streaming session.
  """
  def start_torrent_session(_parent, args, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        %{magnet_link: magnet_link, release_title: release_title} = args

        # Extract IDs from arguments
        media_item_id = args[:media_item_id]
        episode_id = args[:episode_id]
        tmdb_id = args[:tmdb_id]
        tvdb_id = args[:tvdb_id]

        # Handle virtual IDs passed in media_item_id or episode_id
        {media_item_id, episode_id, tmdb_id, tvdb_id} =
          cond do
            not is_nil(media_item_id) ->
              case MydiaWeb.Schema.Resolvers.NodeId.decode(media_item_id) do
                {:tmdb, id} -> {nil, nil, id, tvdb_id}
                {:tvdb, id} -> {nil, nil, tmdb_id, id}
                _ -> {media_item_id, nil, tmdb_id, tvdb_id}
              end

            not is_nil(episode_id) ->
              case MydiaWeb.Schema.Resolvers.NodeId.decode(episode_id) do
                {:tmdb_episode, id, _s, _e} -> {nil, nil, id, tvdb_id}
                {:tvdb_episode, id, _s, _e} -> {nil, nil, tmdb_id, id}
                _ -> {nil, episode_id, tmdb_id, tvdb_id}
              end

            true ->
              {nil, nil, tmdb_id, tvdb_id}
          end

        with :ok <- validate_torrent_session_target(media_item_id, episode_id, tmdb_id, tvdb_id),
             :ok <- ensure_local_media_item_present(media_item_id, episode_id),
             :ok <- ensure_magnet_from_candidate_cache(user.id, magnet_link) do
          attrs = %{
            user_id: user.id,
            magnet: magnet_link,
            release_title: release_title,
            media_item_id: media_item_id,
            episode_id: episode_id,
            state: :initializing
          }

          # If it's an external item, we might want to store the provider ID
          # but for now the SessionSchema doesn't support it.
          # We'll just start the session without a DB link for now.

          case Mydia.Streaming.Torrent.start_session(attrs) do
            {:ok, %{session: session}} ->
              # Automatically add the torrent to the session
              case Mydia.Streaming.Torrent.add_torrent(session.id, magnet_link) do
                {:ok, updated_session} ->
                  {:ok, updated_session}

                {:error, reason} ->
                  # Clean up the session so we don't leak a DB row + supervised process
                  Logger.warning(
                    "add_torrent failed for session #{session.id}, cleaning up: #{inspect(reason)}"
                  )

                  Mydia.Streaming.Torrent.stop_session(session.id)
                  {:error, "Failed to add torrent: #{inspect(reason)}"}
              end

            {:error, :streaming_disabled} ->
              {:error, "Embedded torrent streaming is disabled by the operator"}

            {:error, :cap_reached} ->
              {:error, "Too many concurrent streams. Try again in a moment."}

            {:error, :already_streaming, existing_id} ->
              # A non-terminal session for this infohash already exists.
              # Return the existing session record so the player can attach
              # to it rather than fail the playback start.
              case Mydia.Repo.get(Mydia.Streaming.Torrent.SessionSchema, existing_id) do
                nil ->
                  # The cap-checking row vanished between the lookup and now;
                  # surface a clean error rather than a stale id.
                  {:error, "Another session for this torrent is already active"}

                existing_session ->
                  {:ok, existing_session}
              end

            {:error, reason} ->
              Logger.error("Failed to start torrent session: #{inspect(reason)}")
              {:error, "Failed to start torrent session"}
          end
        end
    end
  end

  # Reject magnets that weren't returned to this user from torrentCandidates.
  # Interim guard for the candidate-id-based hardening (#13).
  defp ensure_magnet_from_candidate_cache(user_id, magnet) do
    if CandidateCache.member?(user_id, magnet) do
      :ok
    else
      {:error,
       "Magnet does not match any recent torrentCandidates result for this user. " <>
         "Re-run torrentCandidates and select a returned candidate."}
    end
  end

  # External-ID-only sessions silently orphan today: validation passes, the
  # row is created with media_item_id: nil, and the playback promotion hook
  # never matches (it keys on media_item_id). Reject the mutation explicitly
  # until the import-first-then-stream flow lands.
  defp ensure_local_media_item_present(media_item_id, episode_id)
       when is_binary(media_item_id) or is_binary(episode_id),
       do: :ok

  defp ensure_local_media_item_present(nil, nil) do
    {:error,
     "Streaming with only a TMDb/TVDb id is not supported yet. " <>
       "Import the title into your library first, then stream."}
  end

  defp ensure_local_media_item_present(_, _), do: :ok

  @doc """
  Lists active torrent streaming sessions. Admin only.
  """
  def active_torrent_sessions(_parent, _args, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        if Map.get(user, :role) == :admin do
          {:ok, Mydia.Streaming.Torrent.list_active_sessions()}
        else
          {:error, "Not authorized"}
        end
    end
  end

  @doc """
  Ends a torrent streaming session.
  """
  def end_torrent_session(_parent, %{session_id: session_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        case Mydia.Repo.get(Mydia.Streaming.Torrent.SessionSchema, session_id) do
          nil ->
            # Idempotent: session may have already been stopped/timed out.
            {:ok, true}

          session ->
            cond do
              session.user_id == user.id ->
                Mydia.Streaming.Torrent.stop_session(session_id)
                {:ok, true}

              Map.get(user, :role) == :admin ->
                Mydia.Streaming.Torrent.stop_session(session_id)
                {:ok, true}

              true ->
                {:error, "Not authorized"}
            end
        end
    end
  end

  # Private functions

  defp start_session_for_user(file_id, user_id, strategy, max_bitrate) do
    # Convert strategy to mode
    mode = strategy_to_mode(strategy)

    # Build session opts
    session_opts = if max_bitrate, do: [max_bitrate: max_bitrate], else: []

    with {:ok, media_file} <- load_media_file(file_id),
         :ok <- Candidates.ensure_codec_info_async(media_file),
         {:ok, pid} <-
           HlsSessionSupervisor.start_session(media_file.id, user_id, mode, session_opts),
         {:ok, info} <- HlsSession.get_info(pid) do
      # Extract duration from media file metadata
      duration = get_duration_from_metadata(media_file)

      Logger.info(
        "Started streaming session #{info.session_id} for file #{file_id}, user #{user_id}" <>
          if(max_bitrate, do: " (max_bitrate: #{max_bitrate}kbps)", else: "")
      )

      # Fire Trakt scrobble start
      content_id = resolve_content_id(media_file)
      Mydia.Integrations.Trakt.Scrobbler.scrobble_start(user_id, content_id)

      {:ok,
       %{
         session_id: info.session_id,
         duration: duration
       }}
    else
      {:error, reason} ->
        Logger.error("Failed to start streaming session: #{inspect(reason)}")
        {:error, "Failed to start streaming session"}
    end
  end

  defp load_media_file(file_id) do
    {:ok, Library.get_media_file!(file_id, preload: [:library_path])}
  rescue
    Ecto.NoResultsError ->
      {:error, :not_found}
  end

  defp validate_torrent_session_target(media_item_id, episode_id, tmdb_id, tvdb_id) do
    provided_targets =
      [media_item_id, episode_id, tmdb_id, tvdb_id]
      |> Enum.reject(&is_nil/1)
      |> length()

    cond do
      provided_targets == 0 ->
        {:error, "Either media_item_id, episode_id, tmdb_id, or tvdb_id must be provided"}

      provided_targets > 1 ->
        {:error, "Exactly one of media_item_id, episode_id, tmdb_id, or tvdb_id must be provided"}

      true ->
        :ok
    end
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
