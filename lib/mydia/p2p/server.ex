defmodule Mydia.P2p.Server do
  @moduledoc """
  GenServer that manages the iroh-based p2p host.

  This server wraps the Rust NIF and handles p2p events, forwarding
  pairing requests to the appropriate handlers.
  """
  use GenServer
  require Logger

  alias Mydia.Auth.Guardian
  alias Mydia.P2p
  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.DirectUrls
  alias Mydia.RemoteAccess.Pairing
  alias Mydia.Streaming.HlsSession
  alias Mydia.Streaming.SessionFiles
  alias Mydia.Streaming.SessionSubtitles
  alias MydiaWeb.Schema.Middleware.Logging, as: GraphQLLogging

  @doc """
  Status information about the p2p host.
  """
  defmodule Status do
    defstruct [
      :node_id,
      :node_addr,
      :running,
      :connected_peers,
      :relay_connected,
      :relay_url,
      :peer_connection_type
    ]

    @type t :: %__MODULE__{
            node_id: String.t() | nil,
            node_addr: String.t() | nil,
            running: boolean(),
            connected_peers: non_neg_integer(),
            relay_connected: boolean(),
            relay_url: String.t() | nil,
            peer_connection_type: String.t() | nil
          }
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Default to our own relay; override via IROH_RELAY_URL env var
    relay_url = System.get_env("IROH_RELAY_URL", "https://cae1-1.relay.mydia.dev")

    # Get bind_port from config (required for hole punching in Docker)
    bind_port = Application.get_env(:mydia, :p2p_bind_port)

    # Get keypair_path from config for persistent node identity
    # This is REQUIRED - without it, the node ID changes on restart and paired devices can't reconnect
    keypair_path =
      Application.get_env(:mydia, :p2p_keypair_path) ||
        raise """
        P2P keypair path not configured!

        The p2p_keypair_path config is required for persistent node identity.
        Without it, paired devices will not be able to reconnect after server restart.

        Add to your config:

            config :mydia, :p2p_keypair_path, "/path/to/p2p_keypair.bin"

        Or set the P2P_KEYPAIR_PATH environment variable.
        """

    # The derived default lands under the data directory, which on a fresh
    # install does not exist yet. The NIF cannot create it.
    keypair_path |> Path.dirname() |> File.mkdir_p!()

    # Start the host - NIF returns {resource, node_id} directly (raises on error)
    {resource, node_id} = P2p.start_host(relay_url, bind_port, keypair_path)

    Logger.info("P2P Host started with NodeID: #{node_id}, relay: #{relay_url}")

    Logger.info("P2P Host using persistent keypair at #{keypair_path}")

    if bind_port do
      Logger.info("P2P Host using UDP port #{bind_port}")
    else
      Logger.info("P2P Host using random port")
    end

    # Start listening for events, sending them to self()
    # NIF returns "ok" directly (raises on error)
    "ok" = P2p.start_listening(resource, self())

    state = %{
      resource: resource,
      node_id: node_id,
      node_addr: nil,
      relay_connected: false,
      # Track connected peers (Map of peer_id => connection_type)
      connected_peers: %{}
    }

    {:ok, state}
  end

  @doc """
  Dial a peer using their EndpointAddr JSON.
  """
  def dial(endpoint_addr_json) do
    GenServer.call(__MODULE__, {:dial, endpoint_addr_json})
  end

  @doc """
  Get the node ID (PublicKey) of this p2p host.
  """
  def node_id do
    GenServer.call(__MODULE__, :node_id)
  end

  @doc """
  Get this node's EndpointAddr as JSON for sharing with other peers.
  """
  def get_node_addr do
    GenServer.call(__MODULE__, :get_node_addr)
  end

  @doc """
  Get the current status of the p2p host.
  """
  @spec status() :: Status.t()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Get network statistics from the p2p host.
  """
  @spec network_stats() :: P2p.NetworkStats.t()
  def network_stats do
    GenServer.call(__MODULE__, :network_stats)
  end

  # GenServer callbacks

  @impl true
  def handle_call({:dial, endpoint_addr_json}, _from, state) do
    result = P2p.dial(state.resource, endpoint_addr_json)
    {:reply, result, state}
  end

  def handle_call(:node_id, _from, state) do
    {:reply, state.node_id, state}
  end

  def handle_call(:get_node_addr, _from, state) do
    node_addr = P2p.get_node_addr(state.resource)
    {:reply, enrich_node_addr(node_addr), state}
  end

  def handle_call(:status, _from, state) do
    # Get relay info from NIF, with fallback if NIF resource isn't ready yet
    {relay_connected, relay_url, peer_connection_type} =
      try do
        network_stats = P2p.get_network_stats(state.resource)
        relay_url = network_stats.relay_url || extract_relay_url_from_node_addr(state.node_addr)

        pct =
          if network_stats.peer_connection_type != "none",
            do: network_stats.peer_connection_type,
            else: nil

        {network_stats.relay_connected, relay_url, pct}
      rescue
        ArgumentError ->
          Logger.warning("P2P: get_network_stats NIF not ready, returning defaults")
          {false, extract_relay_url_from_node_addr(state.node_addr), nil}
      end

    status = %Status{
      node_id: state.node_id,
      node_addr: state.node_addr,
      running: true,
      connected_peers: map_size(state.connected_peers),
      relay_connected: relay_connected,
      relay_url: relay_url,
      peer_connection_type: peer_connection_type
    }

    {:reply, status, state}
  end

  def handle_call(:network_stats, _from, state) do
    stats =
      try do
        P2p.get_network_stats(state.resource)
      rescue
        ArgumentError ->
          Logger.warning("P2P: get_network_stats NIF not ready")

          %P2p.NetworkStats{
            connected_peers: 0,
            relay_connected: false,
            relay_url: nil,
            peer_connection_type: "none"
          }
      end

    {:reply, stats, state}
  end

  # Handle events from Rust NIF

  @impl true
  def handle_info({:ok, "peer_connected", peer_id, connection_type}, state) do
    Logger.info("P2P Event: Peer Connected #{peer_id} (#{connection_type})")
    state = %{state | connected_peers: Map.put(state.connected_peers, peer_id, connection_type)}
    {:noreply, state}
  end

  def handle_info({:ok, "peer_connection_type_changed", peer_id, connection_type}, state) do
    Logger.info("P2P Event: Connection type changed for #{peer_id}: #{connection_type}")
    state = %{state | connected_peers: Map.put(state.connected_peers, peer_id, connection_type)}
    {:noreply, state}
  end

  def handle_info({:ok, "peer_disconnected", peer_id}, state) do
    Logger.info("P2P Event: Peer Disconnected #{peer_id}")
    state = %{state | connected_peers: Map.delete(state.connected_peers, peer_id)}
    {:noreply, state}
  end

  def handle_info({:ok, "relay_connected"}, state) do
    Logger.info("P2P Event: Relay Connected")
    state = %{state | relay_connected: true}
    {:noreply, state}
  end

  def handle_info({:ok, "ready", node_addr}, state) do
    Logger.info("P2P Event: Ready with address")
    enriched = enrich_node_addr(node_addr)
    Logger.debug("Node address: #{enriched}")
    state = %{state | node_addr: enriched}
    {:noreply, state}
  end

  def handle_info({:ok, "request_received", "pairing", request_id, req}, state) do
    Logger.info("P2P Request: Pairing from #{req.device_name}")

    response =
      if RemoteAccess.enabled?() do
        handle_pairing_request(req)
      else
        Logger.info("P2P Request: Pairing refused, remote access is disabled")

        %P2p.PairingResponse{
          success: false,
          error: "Remote access is disabled on this server"
        }
      end

    # Wrap in tagged enum tuple as expected by NIF
    response_enum = {:pairing, response}

    P2p.send_response(state.resource, request_id, response_enum)
    {:noreply, state}
  end

  def handle_info({:ok, "request_received", "ping", _request_id}, state) do
    Logger.debug("P2P Ping Request received")
    {:noreply, state}
  end

  def handle_info({:ok, "request_received", "read_media", request_id, req}, state) do
    cond do
      not RemoteAccess.enabled?() ->
        P2p.send_response(state.resource, request_id, {:error, "Remote access is disabled"})

      # Validate file path exists
      # SECURITY: In production, verify path is within allowed directories!
      File.exists?(req.file_path) ->
        # Use the optimized NIF to read chunk and respond
        P2p.respond_with_file_chunk(
          state.resource,
          request_id,
          req.file_path,
          req.offset,
          req.length
        )

      true ->
        Logger.warning("Requested file not found: #{req.file_path}")
        P2p.send_response(state.resource, request_id, {:error, "File not found"})
    end

    {:noreply, state}
  end

  def handle_info({:ok, "request_received", "graphql", request_id, req}, state) do
    if RemoteAccess.enabled?() do
      handle_graphql_request(request_id, req, state)
    else
      Logger.debug("P2P Request: GraphQL refused, remote access is disabled")

      response = %P2p.GraphQLResponse{
        data: nil,
        errors: encode_graphql_errors([%{message: "Remote access is disabled on this server"}])
      }

      P2p.send_response(state.resource, request_id, {:graphql, response})
      {:noreply, state}
    end
  end

  def handle_info({:ok, "unknown_request"}, state) do
    Logger.debug("P2P: Unknown request type received")
    {:noreply, state}
  end

  def handle_info({:ok, "hls_stream", stream_id, req}, state) do
    Logger.debug("P2P Request: HLS stream session=#{req.session_id} path=#{req.path}")

    resource = state.resource

    # Spawn a task to handle the streaming so we don't block the GenServer
    Task.start(fn ->
      t0 = System.monotonic_time(:millisecond)
      handle_hls_stream(resource, stream_id, req)
      elapsed = System.monotonic_time(:millisecond) - t0

      Logger.info(
        "p2p_metrics_elixir: handler_complete total_ms=#{elapsed} session=#{req.session_id} path=#{req.path}"
      )
    end)

    {:noreply, state}
  end

  # Handle Rust/iroh log messages
  def handle_info({:ok, "log", level, target, message}, state) do
    # Forward Rust logs to Elixir Logger with appropriate level
    log_message = "[#{target}] #{message}"

    case level do
      "trace" -> Logger.debug(log_message, rust_target: target)
      "debug" -> Logger.debug(log_message, rust_target: target)
      "info" -> Logger.info(log_message, rust_target: target)
      "warn" -> Logger.warning(log_message, rust_target: target)
      "error" -> Logger.error(log_message, rust_target: target)
      _ -> Logger.debug(log_message, rust_target: target)
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("P2P Unhandled Event: #{inspect(msg)}")
    {:noreply, state}
  end

  # HLS streaming handler

  defp handle_pairing_request(req) do
    device_attrs = %{
      device_name: req.device_name,
      platform: req.device_type || req.device_os || "unknown"
    }

    # Get direct URLs from config for the client to use.
    # get_config/0 returns the struct or nil, never {:ok, config}.
    direct_urls =
      case RemoteAccess.get_config() do
        nil -> []
        config -> config.direct_urls || []
      end

    case Pairing.complete_pairing(req.claim_code, device_attrs) do
      {:ok, _device, media_token, access_token, device_token} ->
        %P2p.PairingResponse{
          success: true,
          media_token: media_token,
          access_token: access_token,
          device_token: device_token,
          error: nil,
          direct_urls: direct_urls
        }

      {:error, reason} ->
        Logger.warning("Pairing failed: #{inspect(reason)}")

        %P2p.PairingResponse{
          success: false,
          error: inspect(reason)
        }
    end
  end

  defp handle_graphql_request(request_id, req, state) do
    Logger.debug("P2P Request: GraphQL query")

    # Parse variables from JSON
    variables = parse_graphql_variables(req.variables)

    # Build context from auth token, marking source as p2p
    # Include peer connection type so resolvers can enforce relay caps
    peer_connection_type = infer_peer_connection_type(state.connected_peers)
    context = build_graphql_context(req.auth_token, :p2p, peer_connection_type)

    # Execute the GraphQL query with logging
    result =
      GraphQLLogging.run(
        req.query,
        MydiaWeb.Schema,
        variables: variables,
        operation_name: req.operation_name,
        context: context
      )

    response =
      case result do
        {:ok, %{data: data, errors: errors}} ->
          %P2p.GraphQLResponse{
            data: encode_json(data),
            errors: encode_graphql_errors(errors)
          }

        {:ok, %{data: data}} ->
          %P2p.GraphQLResponse{
            data: encode_json(data),
            errors: nil
          }

        # Query validation errors (no data key, only errors)
        {:ok, %{errors: errors}} ->
          Logger.warning("GraphQL validation error: #{inspect(errors)}")

          %P2p.GraphQLResponse{
            data: nil,
            errors: encode_graphql_errors(errors)
          }

        {:error, reason} ->
          Logger.warning("GraphQL execution failed: #{inspect(reason)}")

          %P2p.GraphQLResponse{
            data: nil,
            errors: encode_json([%{message: inspect(reason)}])
          }
      end

    P2p.send_response(state.resource, request_id, {:graphql, response})
    {:noreply, state}
  end

  defp handle_hls_stream(resource, stream_id, req) do
    t0 = System.monotonic_time(:millisecond)

    # Verify auth token
    case verify_hls_auth(req.auth_token) do
      {:ok, user} ->
        auth_ms = System.monotonic_time(:millisecond) - t0

        Logger.info(
          "p2p_metrics_elixir: auth_complete auth_ms=#{auth_ms} session=#{req.session_id} path=#{req.path}"
        )

        cond do
          String.starts_with?(req.session_id, "direct:") ->
            file_id = String.replace_prefix(req.session_id, "direct:", "")
            handle_direct_stream(resource, stream_id, file_id, user, req)

          String.starts_with?(req.session_id, "download:") ->
            job_id = String.replace_prefix(req.session_id, "download:", "")
            handle_download_stream(resource, stream_id, job_id, req)

          true ->
            handle_hls_session_stream(resource, stream_id, req)
        end

      {:error, _reason} ->
        auth_ms = System.monotonic_time(:millisecond) - t0
        Logger.warning("HLS auth failed (auth_ms=#{auth_ms})")
        send_hls_error(resource, stream_id, 401, "Unauthorized")
    end
  end

  defp handle_hls_session_stream(resource, stream_id, req) do
    # Look up the session by session_id
    case lookup_hls_session(req.session_id) do
      {:ok, pid, session_info} ->
        # Wait for the session to be ready (FFmpeg has created initial files)
        case HlsSession.await_ready(pid, 30_000) do
          :ok ->
            case resolve_session_file(session_info, req.path) do
              {:ok, file_path} ->
                stream_hls_file(resource, stream_id, file_path, req)

              {:error, :path_traversal} ->
                Logger.warning("HLS path validation failed for #{req.path}")
                send_hls_error(resource, stream_id, 403, "Forbidden")

              {:error, :image_subtitle} ->
                Logger.debug("HLS subtitle unavailable: image-based track #{req.path}")

                send_hls_error(
                  resource,
                  stream_id,
                  415,
                  "Image-based subtitles cannot be converted to text"
                )

              {:error, reason} ->
                Logger.warning("HLS file unavailable: #{inspect(reason)}")
                send_hls_error(resource, stream_id, 404, "Not found")
            end

          {:error, :timeout} ->
            Logger.warning("HLS session #{req.session_id} not ready after timeout")
            send_hls_error(resource, stream_id, 503, "Transcoding not ready")

          {:error, {:session_exit, reason}} ->
            Logger.warning("HLS session #{req.session_id} terminated: #{inspect(reason)}")
            send_hls_error(resource, stream_id, 503, "Session terminated")
        end

      {:error, :not_found} ->
        Logger.warning("HLS session not found: #{req.session_id}")
        send_hls_error(resource, stream_id, 404, "Session not found")
    end
  end

  defp handle_direct_stream(resource, stream_id, file_id, user, req) do
    try do
      media_file = Mydia.Library.get_media_file!(file_id, preload: [:library_path])

      case Mydia.Library.MediaFile.absolute_path(media_file) do
        nil ->
          Logger.warning("Direct stream: cannot resolve path for file #{file_id}")
          send_hls_error(resource, stream_id, 404, "File path not found")

        absolute_path ->
          if File.exists?(absolute_path) do
            # Start or reuse a direct play session for tracking
            case Mydia.Streaming.HlsSessionSupervisor.start_direct_session(
                   media_file.id,
                   user.id
                 ) do
              {:ok, pid, :started} ->
                Logger.info(
                  "P2P Direct Play started: file=#{file_id}, path=#{Path.basename(absolute_path)}"
                )

                Mydia.Streaming.DirectPlaySession.heartbeat(pid)

              {:ok, pid, :existing} ->
                Mydia.Streaming.DirectPlaySession.heartbeat(pid)

              _ ->
                :ok
            end

            stream_hls_file(resource, stream_id, absolute_path, req)
          else
            Logger.warning("Direct stream: file not found at #{absolute_path}")
            send_hls_error(resource, stream_id, 404, "File not found on disk")
          end
      end
    rescue
      Ecto.NoResultsError ->
        Logger.warning("Direct stream: media file #{file_id} not found in database")
        send_hls_error(resource, stream_id, 404, "Media file not found")
    end
  end

  defp handle_download_stream(resource, stream_id, job_id, req) do
    case lookup_transcode_job(job_id) do
      {:ok, job} ->
        stream_hls_file(resource, stream_id, job.output_path, req)

      {:error, :not_found} ->
        Logger.warning("Download stream: job #{job_id} not found")
        send_hls_error(resource, stream_id, 404, "Job not found")

      {:error, :not_ready} ->
        Logger.warning("Download stream: job #{job_id} not ready")
        send_hls_error(resource, stream_id, 503, "Job not ready")
    end
  end

  defp verify_hls_auth(nil), do: {:error, :no_token}

  defp verify_hls_auth(auth_token) when is_binary(auth_token) do
    case Guardian.verify_token_with_claims(auth_token) do
      {:ok, user, claims} ->
        RemoteAccess.touch_device_from_claims(claims)
        {:ok, user}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lookup_hls_session(session_id) do
    case Registry.lookup(Mydia.Streaming.HlsSessionRegistry, {:session, session_id}) do
      [{pid, info}] ->
        # Trigger heartbeat to keep session alive
        HlsSession.heartbeat(pid)
        {:ok, pid, info}

      [] ->
        {:error, :not_found}
    end
  end

  # A subtitle is materialized on demand; anything else is an ordinary file
  # that either exists in the session directory or does not.
  defp resolve_session_file(info, name) do
    case SessionSubtitles.ensure(info, name) do
      :not_subtitle -> SessionFiles.safe_path(info.temp_dir, name)
      result -> result
    end
  end

  defp stream_hls_file(resource, stream_id, file_path, req) do
    try do
      do_stream_hls_file(resource, stream_id, file_path, req)
    rescue
      e ->
        Logger.error(
          "HLS stream failed for #{file_path}: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
        )

        :ok
    end
  end

  defp do_stream_hls_file(resource, stream_id, file_path, req) do
    t0 = System.monotonic_time(:millisecond)

    case File.stat(file_path) do
      {:ok, %File.Stat{size: file_size}} ->
        file_stat_ms = System.monotonic_time(:millisecond) - t0

        # Determine content type
        content_type = SessionFiles.content_type(file_path)
        basename = Path.basename(file_path)

        # Handle range requests
        case parse_range(req.range_start, req.range_end, file_size) do
          {:full, _} ->
            # Full file request
            send_full_hls_file(resource, stream_id, file_path, file_size, content_type)

            stream_ms = System.monotonic_time(:millisecond) - t0

            Logger.info(
              "p2p_metrics_elixir: file_stream file_stat_ms=#{file_stat_ms} stream_ms=#{stream_ms} bytes=#{file_size} path=#{basename} session=#{req.session_id}"
            )

          {:partial, range_start, range_end, content_length} ->
            # Partial content (206)
            send_partial_hls_file(
              resource,
              stream_id,
              file_path,
              file_size,
              range_start,
              range_end,
              content_length,
              content_type
            )

            stream_ms = System.monotonic_time(:millisecond) - t0

            Logger.info(
              "p2p_metrics_elixir: file_stream file_stat_ms=#{file_stat_ms} stream_ms=#{stream_ms} bytes=#{content_length}/#{file_size} range=#{range_start}-#{range_end} path=#{basename} session=#{req.session_id}"
            )
        end

      {:error, :enoent} ->
        Logger.debug("HLS file not found: #{file_path}")
        send_hls_error(resource, stream_id, 404, "Not found")

      {:error, reason} ->
        Logger.warning("HLS file error: #{inspect(reason)}")
        send_hls_error(resource, stream_id, 500, "Internal error")
    end
  end

  defp parse_range(nil, nil, file_size), do: {:full, file_size}

  defp parse_range(range_start, range_end, file_size) do
    # Calculate actual range
    start_byte = range_start || 0
    end_byte = min(range_end || file_size - 1, file_size - 1)
    content_length = end_byte - start_byte + 1

    {:partial, start_byte, end_byte, content_length}
  end

  defp send_full_hls_file(resource, stream_id, file_path, file_size, content_type) do
    t0 = System.monotonic_time(:millisecond)

    # Send header
    header = %P2p.HlsResponseHeader{
      status: 200,
      content_type: content_type,
      content_length: file_size,
      content_range: nil,
      cache_control: hls_cache_control(file_path)
    }

    case P2p.send_hls_header(resource, stream_id, header) do
      "ok" ->
        send_header_ms = System.monotonic_time(:millisecond) - t0

        # Stream the file directly from Rust (zero-copy, no per-chunk NIF overhead)
        case P2p.stream_file_range(resource, stream_id, file_path, 0, file_size) do
          "ok" ->
            stream_file_range_ms = System.monotonic_time(:millisecond) - t0 - send_header_ms

            Logger.info(
              "p2p_metrics_elixir: nif_breakdown send_header_ms=#{send_header_ms} stream_file_range_ms=#{stream_file_range_ms} bytes=#{file_size} path=#{Path.basename(file_path)}"
            )

          {:error, reason} ->
            Logger.error("Failed to stream file: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("Failed to send HLS header: #{inspect(reason)}")
    end
  end

  defp send_partial_hls_file(
         resource,
         stream_id,
         file_path,
         file_size,
         range_start,
         range_end,
         content_length,
         content_type
       ) do
    t0 = System.monotonic_time(:millisecond)

    # Send header with 206 status
    header = %P2p.HlsResponseHeader{
      status: 206,
      content_type: content_type,
      content_length: content_length,
      content_range: "bytes #{range_start}-#{range_end}/#{file_size}",
      cache_control: hls_cache_control(file_path)
    }

    case P2p.send_hls_header(resource, stream_id, header) do
      "ok" ->
        send_header_ms = System.monotonic_time(:millisecond) - t0

        # Stream the file range directly from Rust (zero-copy, no per-chunk NIF overhead)
        case P2p.stream_file_range(resource, stream_id, file_path, range_start, content_length) do
          "ok" ->
            stream_file_range_ms = System.monotonic_time(:millisecond) - t0 - send_header_ms

            Logger.info(
              "p2p_metrics_elixir: nif_breakdown send_header_ms=#{send_header_ms} stream_file_range_ms=#{stream_file_range_ms} bytes=#{content_length} path=#{Path.basename(file_path)}"
            )

          {:error, reason} ->
            Logger.error("Failed to stream file range: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("Failed to send HLS header: #{inspect(reason)}")
    end
  end

  defp send_hls_error(resource, stream_id, status, message) do
    # Send error as header-only response
    # Wrapped in try/rescue because the P2P stream may already be closed
    # (e.g. peer disconnected), causing NIF calls to raise ArgumentError
    header = %P2p.HlsResponseHeader{
      status: status,
      content_type: "text/plain",
      content_length: byte_size(message),
      content_range: nil,
      cache_control: nil
    }

    try do
      case P2p.send_hls_header(resource, stream_id, header) do
        "ok" ->
          P2p.send_hls_chunk(resource, stream_id, message)
          P2p.finish_hls_stream(resource, stream_id)

        _ ->
          :ok
      end
    rescue
      e ->
        Logger.debug("Failed to send HLS error response: #{inspect(e)}")
        :ok
    end
  end

  defp hls_cache_control(path) do
    case Path.extname(path) do
      # Playlists should not be cached (may update)
      ".m3u8" -> "no-cache"
      # Segments can be cached longer
      ".ts" -> "max-age=86400"
      # A subtitle body is stable for the life of the session but not
      # immutable across sessions, and it is small enough that revalidation
      # costs nothing. Matches HlsController's cache_control_for/1.
      ".vtt" -> "no-cache"
      _ -> nil
    end
  end

  # Private helpers for GraphQL handling

  defp parse_graphql_variables(nil), do: %{}

  defp parse_graphql_variables(variables_json) when is_binary(variables_json) do
    case Jason.decode(variables_json) do
      {:ok, variables} when is_map(variables) -> variables
      _ -> %{}
    end
  end

  defp build_graphql_context(nil, source, peer_connection_type),
    do: %{source: source, peer_connection_type: peer_connection_type}

  defp build_graphql_context(auth_token, source, peer_connection_type)
       when is_binary(auth_token) do
    # Use Guardian to verify the token and get the user
    case Guardian.verify_token_with_claims(auth_token) do
      {:ok, user, claims} ->
        # Paired players reach the backend over p2p and nowhere else, so this is
        # the only place device liveness can be observed. The remote access admin
        # page reads it back as "Online now".
        RemoteAccess.touch_device_from_claims(claims)

        %{current_user: user, source: source, peer_connection_type: peer_connection_type}

      {:error, _reason} ->
        Logger.debug("P2P GraphQL: Invalid auth token")
        %{source: source, peer_connection_type: peer_connection_type}
    end
  end

  # Infer the peer connection type from connected peers map.
  # Returns "relay", "direct", "mixed", or nil if no peers connected.
  defp infer_peer_connection_type(connected_peers) when map_size(connected_peers) == 0, do: nil

  defp infer_peer_connection_type(connected_peers) do
    types = Map.values(connected_peers) |> Enum.uniq()

    case types do
      ["relay"] -> "relay"
      ["direct"] -> "direct"
      _ -> "mixed"
    end
  end

  defp encode_json(nil), do: nil

  defp encode_json(data) do
    case Jason.encode(data) do
      {:ok, json} -> json
      {:error, _} -> nil
    end
  end

  defp encode_graphql_errors(nil), do: nil
  defp encode_graphql_errors([]), do: nil

  defp encode_graphql_errors(errors) when is_list(errors) do
    # Convert Absinthe errors to a JSON-serializable format
    serializable_errors =
      Enum.map(errors, fn error ->
        %{
          message: Map.get(error, :message, inspect(error)),
          locations: Map.get(error, :locations),
          path: Map.get(error, :path)
        }
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)
        |> Map.new()
      end)

    encode_json(serializable_errors)
  end

  # Enrich a node_addr JSON with additional direct IP addresses detected from
  # network interfaces and public IP services. This gives iroh more paths to
  # attempt direct connections, which is especially useful in Docker or NAT
  # environments where iroh's auto-detection may miss IPs.
  defp enrich_node_addr(nil), do: nil

  defp enrich_node_addr(node_addr_json) when is_binary(node_addr_json) do
    with {:ok, %{"id" => id, "addrs" => addrs}} when is_list(addrs) <-
           Jason.decode(node_addr_json),
         {:ok, iroh_port} <- extract_iroh_port(addrs) do
      existing_ips = extract_existing_ips(addrs)
      detected_ips = DirectUrls.detect_all_ips()

      new_ip_entries =
        detected_ips
        |> Enum.reject(fn ip -> MapSet.member?(existing_ips, ip) end)
        |> Enum.map(fn {a, b, c, d} -> %{"Ip" => "#{a}.#{b}.#{c}.#{d}:#{iroh_port}"} end)

      if new_ip_entries == [] do
        node_addr_json
      else
        enriched = %{"id" => id, "addrs" => addrs ++ new_ip_entries}

        Logger.info(
          "Enriched node_addr with #{length(new_ip_entries)} additional IP(s): #{Enum.map_join(new_ip_entries, ", ", & &1["Ip"])}"
        )

        Jason.encode!(enriched)
      end
    else
      _ -> node_addr_json
    end
  end

  # Extract the iroh QUIC port from existing Ip entries in the addrs list.
  # Returns {:ok, port} from the first Ip entry, or :error if none found.
  defp extract_iroh_port(addrs) do
    Enum.find_value(addrs, :error, fn
      %{"Ip" => ip_port} ->
        case String.split(ip_port, ":") do
          [_ip, port_str] ->
            case Integer.parse(port_str) do
              {port, ""} -> {:ok, port}
              _ -> nil
            end

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  # Extract existing IP tuples from addrs for deduplication.
  defp extract_existing_ips(addrs) do
    addrs
    |> Enum.flat_map(fn
      %{"Ip" => ip_port} ->
        case String.split(ip_port, ":") do
          [ip_str, _port] ->
            case ip_str |> String.to_charlist() |> :inet.parse_address() do
              {:ok, {a, b, c, d} = tuple}
              when is_integer(a) and is_integer(b) and is_integer(c) and is_integer(d) ->
                [tuple]

              _ ->
                []
            end

          _ ->
            []
        end

      _ ->
        []
    end)
    |> MapSet.new()
  end

  # Extract the relay URL from the node_addr JSON
  # The node_addr is a JSON object like:
  # {"id": "...", "addrs": [{"Relay": "https://..."}, {"Ip": "1.2.3.4:5678"}]}
  defp extract_relay_url_from_node_addr(nil), do: nil

  defp extract_relay_url_from_node_addr(node_addr_json) when is_binary(node_addr_json) do
    case Jason.decode(node_addr_json) do
      {:ok, %{"addrs" => addrs}} when is_list(addrs) ->
        # Find the first Relay address
        Enum.find_value(addrs, fn
          %{"Relay" => relay_url} -> relay_url
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp lookup_transcode_job(job_id) do
    alias Mydia.Downloads.TranscodeJob
    alias Mydia.Repo

    # Look up the transcode job by ID
    case Repo.get(TranscodeJob, job_id) do
      nil ->
        {:error, :not_found}

      job ->
        # Check if the job is ready (transcoding complete)
        if (job.status == "ready" and job.output_path) && File.exists?(job.output_path) do
          {:ok, job}
        else
          {:error, :not_ready}
        end
    end
  end
end
