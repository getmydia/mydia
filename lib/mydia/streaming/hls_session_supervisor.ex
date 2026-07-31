defmodule Mydia.Streaming.HlsSessionSupervisor do
  @moduledoc """
  DynamicSupervisor managing HLS transcoding sessions.

  This supervisor starts and manages HLS sessions on-demand. Each session
  is uniquely identified by a combination of media_file_id and user_id,
  ensuring that multiple users can stream the same file simultaneously
  (each gets their own transcoding session).

  ## Usage

      # Start or get existing session for a user/file combination
      {:ok, pid} = HlsSessionSupervisor.start_session(123, 456)

      # Get existing session
      {:ok, pid} = HlsSessionSupervisor.get_session(123, 456)

      # Stop a session
      HlsSessionSupervisor.stop_session(123, 456)
  """

  use DynamicSupervisor

  alias Mydia.Streaming.HlsSession
  alias Mydia.Streaming.DirectPlaySession

  @registry_name Mydia.Streaming.HlsSessionRegistry

  # See await_deregistration/2 for why this polling wait exists.
  @deregistration_attempts 50
  @deregistration_interval_ms 2

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new HLS session for a media file and user combination.

  If a session already exists for this combination, returns the existing session.

  ## Parameters

    * `media_file_id` - ID of the media file to transcode
    * `user_id` - ID of the user requesting the stream
    * `mode` - (optional) Streaming mode: `:copy` or `:transcode` (default: `:transcode`)

  ## Returns

    * `{:ok, pid}` - Session process
    * `{:error, reason}` - If session failed to start
  """
  def start_session(media_file_id, user_id, mode \\ :transcode, opts \\ []) do
    session_key = session_key(media_file_id, user_id)
    start_position = Keyword.get(opts, :start_position, 0)

    case Registry.lookup(@registry_name, session_key) do
      [{pid, metadata}] ->
        if session_matches_offset?(metadata, start_position) do
          {:ok, pid}
        else
          # A session transcoding from a different offset cannot serve this
          # request: its playlist simply does not contain the wanted range.
          # Replace it rather than keying sessions by offset, so a user
          # scrubbing around does not accumulate concurrent FFmpeg processes.
          DynamicSupervisor.terminate_child(__MODULE__, pid)
          await_deregistration(session_key)
          start_new_session(media_file_id, user_id, mode, opts, session_key)
        end

      [] ->
        start_new_session(media_file_id, user_id, mode, opts, session_key)
    end
  end

  @doc false
  # Public for unit testing. Metadata registered before :start_position existed
  # is treated as offset zero rather than as a wildcard match.
  def session_matches_offset?(metadata, start_position) do
    Map.get(metadata, :start_position, 0) == start_position
  end

  # Registry cleans up a dead process's entry asynchronously, through the
  # monitor it holds. `terminate_child/2` returns as soon as the process is
  # down, which can be before that cleanup lands. On this `:unique` registry an
  # immediate re-register would then come back `{:error, {:already_registered,
  # _}}` — and because `HlsSession.init/1` discards that return value, the new
  # session would run unregistered and be invisible to `get_session/2`, so the
  # HLS controller would fail to serve its playlist while FFmpeg ran happily.
  #
  # Bounded so a wedged entry degrades to the old behaviour instead of hanging
  # the caller.
  @doc false
  # Public for unit testing, same as session_matches_offset?/2.
  def await_deregistration(session_key, attempts \\ @deregistration_attempts)

  def await_deregistration(_session_key, 0), do: :ok

  def await_deregistration(session_key, attempts) do
    case Registry.lookup(@registry_name, session_key) do
      [] ->
        :ok

      _ ->
        Process.sleep(@deregistration_interval_ms)
        await_deregistration(session_key, attempts - 1)
    end
  end

  defp start_new_session(media_file_id, user_id, mode, opts, session_key) do
    session_opts =
      [
        media_file_id: media_file_id,
        user_id: user_id,
        registry_key: session_key,
        mode: mode
      ] ++ opts

    child_spec = %{
      id: HlsSession,
      start: {HlsSession, :start_link, [session_opts]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      # A concurrent caller won the race to register this key (see
      # HlsSession.init/1). Its session is the one we wanted, so adopt it
      # rather than reporting failure.
      {:error, {:already_registered, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc """
  Starts a new Direct Play tracking session.

  Uses a unique registry key different from HLS sessions to allow tracking direct plays separately.
  Handles race conditions using :via tuple registration.
  """
  def start_direct_session(media_file_id, user_id) do
    session_key = {:direct_session, media_file_id, user_id}
    started_at = DateTime.utc_now()

    metadata = %{
      media_file_id: media_file_id,
      user_id: user_id,
      mode: :direct,
      started_at: started_at
    }

    name = {:via, Registry, {@registry_name, session_key, metadata}}

    child_spec = %{
      id: {DirectPlaySession, media_file_id, user_id},
      start:
        {DirectPlaySession, :start_link,
         [
           [
             media_file_id: media_file_id,
             user_id: user_id,
             name: name,
             started_at: started_at
           ]
         ]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, child_spec) do
      {:ok, pid} ->
        {:ok, pid, :started}

      {:error, {:already_started, pid}} ->
        {:ok, pid, :existing}

      error ->
        error
    end
  end

  @doc """
  Stops a Direct Play session.
  """
  def stop_direct_session(media_file_id, user_id) do
    session_key = {:direct_session, media_file_id, user_id}

    case Registry.lookup(@registry_name, session_key) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        :ok
    end
  end

  @doc """
  Gets an existing HLS session for a media file and user combination.

  ## Returns

    * `{:ok, pid}` - If session exists
    * `{:error, :not_found}` - If no session exists
  """
  def get_session(media_file_id, user_id) do
    session_key = session_key(media_file_id, user_id)

    case Registry.lookup(@registry_name, session_key) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Stops an HLS session for a media file and user combination.

  ## Returns

    * `:ok` - Session stopped or didn't exist
  """
  def stop_session(media_file_id, user_id) do
    case get_session(media_file_id, user_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      {:error, :not_found} ->
        :ok
    end
  end

  @doc """
  Lists all active HLS sessions.

  ## Returns

  List of tuples: `{session_key, pid, metadata}`
  """
  def list_sessions do
    Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end

  @doc """
  Counts the number of active sessions.
  """
  def count_sessions do
    DynamicSupervisor.count_children(__MODULE__).active
  end

  # Generate unique session key for registry
  defp session_key(media_file_id, user_id) do
    {:hls_session, media_file_id, user_id}
  end
end
