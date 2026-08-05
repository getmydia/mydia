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
    max_bitrate = Keyword.get(opts, :max_bitrate)
    max_height = Keyword.get(opts, :max_height)

    case Registry.lookup(@registry_name, session_key) do
      [{pid, metadata}] ->
        if session_matches?(metadata, start_position, max_bitrate, max_height) do
          {:ok, pid}
        else
          # A session transcoding from a different offset cannot serve this
          # request: its playlist simply does not contain the wanted range. A
          # session running at a different quality cannot serve it either: its
          # segments are already encoded at the old rung. Replace it rather
          # than keying sessions by offset and quality, so a user scrubbing
          # around or flipping rungs does not accumulate concurrent FFmpeg
          # processes.
          stop_gracefully(pid)
          start_new_session(media_file_id, user_id, mode, opts, session_key)
        end

      [] ->
        start_new_session(media_file_id, user_id, mode, opts, session_key)
    end
  end

  @doc false
  # Public for unit testing. Metadata registered before the quality fields
  # existed is treated as an uncapped session at offset zero rather than as a
  # wildcard that matches any request.
  def session_matches?(metadata, start_position, max_bitrate, max_height) do
    Map.get(metadata, :start_position, 0) == start_position and
      Map.get(metadata, :max_bitrate) == max_bitrate and
      Map.get(metadata, :max_height) == max_height
  end

  # Stops a session the way `endStreamingSession` does, rather than through
  # `DynamicSupervisor.terminate_child/2`. `HlsSession` does not trap exits,
  # so a `:shutdown` signal kills it outright and its `terminate/2` never
  # runs — leaving the `TranscodeJob` row stuck at `status: "transcoding"` in
  # the queue UI forever, the temp directory of `.ts` segments on disk, and no
  # `:session_ended` broadcast. `GenServer.stop/2` is equally synchronous and
  # does run `terminate/2`.
  #
  # Registry cleanup is still asynchronous after this returns, but no wait is
  # needed: `Registry.register/3` on a `:unique` key that collides with a dead
  # owner deletes the stale entry and retries (see `register_key/4` in
  # Elixir's `registry.ex`), and the owner is always dead by the time a
  # synchronous stop returns.
  defp stop_gracefully(pid) do
    HlsSession.stop(pid)
  catch
    # The session died on its own between the registry lookup and this call
    # (inactivity timeout, or its FFmpeg backend exiting). Its `terminate/2`
    # has already run; there is nothing left to stop.
    :exit, _reason -> :ok
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
        # Deliberately NOT stop_gracefully/1, despite the same terminate/2-is-
        # skipped problem described there. Its only caller is
        # Downloads.Transcoding.cancel_transcode_job/1, which stops the
        # session and then does its own `Repo.delete(job)` — running
        # HlsSession.terminate/2 here would delete that row first and turn
        # that delete into an Ecto.StaleEntryError. Switching this over means
        # making that delete tolerant of an already-deleted row, which is a
        # separate change from the offset-replacement path above.
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
