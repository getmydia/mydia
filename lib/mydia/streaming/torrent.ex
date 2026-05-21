defmodule Mydia.Streaming.Torrent do
  @moduledoc """
  The Torrent streaming context.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo

  alias Mydia.Streaming.Torrent.SessionSupervisor
  alias Mydia.Streaming.Torrent.Session
  alias Mydia.Streaming.Torrent.SessionSchema
  alias Mydia.Streaming.Torrent.Promotion

  @default_concurrent_cap 3

  # States that count as "active" for cap enforcement / dup-infohash detection.
  @active_session_states [:initializing, :downloading, :ready, :watching]

  @doc """
  Starts a torrent streaming session.

  Returns:
    * `{:ok, %{session: session, pid: pid}}` on success.
    * `{:error, :streaming_disabled}` if embedded streaming is not enabled in settings.
    * `{:error, :cap_reached}` if the concurrent_cap is at its limit.
    * `{:error, :already_streaming, existing_session_id}` if another non-terminal session
       is already running with the same infohash. Callers (e.g. the GraphQL
       resolver) should surface this as "attach to the existing session" rather
       than as a hard error so a second viewer of the same release joins the
       in-flight download instead of starting a duplicate.
    * `{:error, changeset}` on validation failure.
  """
  def start_session(attrs \\ %{}) do
    with :ok <- ensure_streaming_enabled(),
         :ok <- ensure_under_concurrent_cap(),
         :ok <- ensure_infohash_available(attrs),
         {:ok, session} <- create_session_record(attrs),
         {:ok, pid} <- SessionSupervisor.start_session(session.id) do
      {:ok, %{session: session, pid: pid}}
    end
  end

  defp ensure_streaming_enabled do
    # Check DB-level setting first; the in-memory runtime_config snapshot is
    # populated at boot from the same DB rows, but the admin Settings UI
    # writes to the DB at runtime and broadcasts a {:setting_changed, ...}
    # event without updating the runtime_config snapshot. Querying the DB
    # row directly means a flipped toggle takes effect immediately.
    db_enabled? =
      case Mydia.Settings.get_config_setting_by_key("streaming.embedded_enabled") do
        %{value: "true"} -> true
        %{value: "1"} -> true
        %{value: _} -> false
        nil -> nil
      end

    cond do
      db_enabled? == true -> :ok
      db_enabled? == false -> {:error, :streaming_disabled}
      match?(%{embedded_enabled: true}, Mydia.Settings.get_streaming_config()) -> :ok
      true -> {:error, :streaming_disabled}
    end
  end

  defp ensure_under_concurrent_cap do
    cap =
      case Mydia.Settings.get_streaming_config() do
        %{concurrent_cap: cap} when is_integer(cap) and cap > 0 -> cap
        _ -> @default_concurrent_cap
      end

    if length(SessionSupervisor.list_sessions()) >= cap do
      {:error, :cap_reached}
    else
      :ok
    end
  end

  # We only know the infohash from the magnet (or post-metadata).
  # Detect duplicates at the magnet level when possible — best-effort.
  defp ensure_infohash_available(%{magnet: magnet}) when is_binary(magnet) do
    case extract_infohash_from_magnet(magnet) do
      nil ->
        :ok

      hash ->
        case Repo.one(
               from(s in SessionSchema,
                 where: s.infohash == ^hash and s.state in ^@active_session_states,
                 select: s.id,
                 limit: 1
               )
             ) do
          nil -> :ok
          existing_id -> {:error, :already_streaming, existing_id}
        end
    end
  end

  defp ensure_infohash_available(_), do: :ok

  # Extract an infohash (xt=urn:btih:<hash>) from a magnet URI if present.
  defp extract_infohash_from_magnet(magnet) when is_binary(magnet) do
    case Regex.run(~r/xt=urn:btih:([A-Za-z0-9]+)/i, magnet) do
      [_, hash] -> String.downcase(hash)
      _ -> nil
    end
  end

  defp extract_infohash_from_magnet(_), do: nil

  @doc """
  Returns active torrent sessions for a given user and content target.

  This keeps SessionSchema schema knowledge inside the Torrent context.
  """
  def find_promotable_sessions(user_id, content_id) when is_list(content_id) do
    cond do
      content_id[:media_item_id] ->
        Repo.all(
          from s in SessionSchema,
            where:
              s.user_id == ^user_id and s.media_item_id == ^content_id[:media_item_id] and
                s.state != :completed
        )

      content_id[:episode_id] ->
        Repo.all(
          from s in SessionSchema,
            where:
              s.user_id == ^user_id and s.episode_id == ^content_id[:episode_id] and
                s.state != :completed
        )

      true ->
        []
    end
  end

  @doc """
  Checks if a session should be promoted and initiates it if so.

  Uses an atomic claim — `update_all` flipping `state` from `:ready`/`:watching`
  to `:promoting` — to ensure only one caller advances into `Promotion.promote/1`
  even when two `save_progress` events cross the playback threshold concurrently.

  Outcomes:

    * `{:ok, media_file}` — claim won, promotion succeeded.
    * `{:ok, :not_ready}` — playback hasn't crossed 90% yet.
    * `{:ok, :already_claimed}` — another concurrent caller is mid-promotion.
    * `{:ok, :download_incomplete}` — playback crossed 90% but download did not.
    * `{:error, reason}` — promotion failed; state was rolled back to `:failed`.
  """
  def check_and_promote(session_id) do
    with {:ok, %{session: session}} <- get_active_session(session_id) do
      # Get current progress for the content
      progress =
        cond do
          session.media_item_id ->
            Mydia.Playback.get_progress(session.user_id, media_item_id: session.media_item_id)

          session.episode_id ->
            Mydia.Playback.get_progress(session.user_id, episode_id: session.episode_id)

          true ->
            nil
        end

      if progress && progress.completion_percentage >= 90.0 do
        claim_and_promote(session_id)
      else
        {:ok, :not_ready}
      end
    end
  end

  # Atomically transition the row from :ready/:watching to :promoting. The
  # partial unique infohash index excludes :promoting, so a second viewer can
  # still start their own session while this one is mid-promotion; the
  # exclusive claim is on the work itself, not the resource.
  defp claim_and_promote(session_id) do
    {claimed, _} =
      Repo.update_all(
        from(s in SessionSchema,
          where: s.id == ^session_id and s.state in [:ready, :watching]
        ),
        set: [state: :promoting, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

    case claimed do
      1 ->
        case Promotion.promote(session_id) do
          {:ok, :download_incomplete} = result ->
            # Playback crossed 90% but the download didn't finish; release the
            # claim back to :watching so the next progress event can retry.
            release_claim_to(session_id, :watching)
            result

          {:ok, _} = ok ->
            # Promotion.create_media_file/3 already transitioned the row to
            # :completed on success.
            ok

          {:error, _} = err ->
            # Hard failure; flip to :failed so the partial-index window reopens
            # for a fresh retry path under a new session.
            release_claim_to(session_id, :failed)
            err
        end

      0 ->
        {:ok, :already_claimed}
    end
  end

  defp release_claim_to(session_id, new_state) do
    Repo.update_all(
      from(s in SessionSchema, where: s.id == ^session_id and s.state == :promoting),
      set: [state: new_state, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )

    :ok
  end

  @doc """
  Gets an active session by ID.
  """
  def get_active_session(session_id) do
    with {:ok, pid} <- SessionSupervisor.get_session(session_id),
         session when not is_nil(session) <- Repo.get(SessionSchema, session_id) do
      {:ok, %{session: session, pid: pid}}
    else
      {:error, :not_found} -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Adds a torrent to an active session.
  """
  def add_torrent(session_id, magnet_link) do
    with {:ok, %{pid: pid}} <- get_active_session(session_id),
         :ok <- Session.add_torrent(pid, magnet_link),
         session when not is_nil(session) <- Repo.get(SessionSchema, session_id) do
      {:ok, session}
    else
      {:error, _reason} = error -> error
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Reads a chunk from a torrent session.
  """
  def read_chunk(session_id, file_index, offset, length) do
    with {:ok, %{pid: pid}} <- get_active_session(session_id) do
      Session.read_chunk(pid, file_index, offset, length)
    end
  end

  @doc """
  Returns the in-process torrent resource and torrent_id for a session.

  Lets hot-path callers (the P2P stream handler) call the DirtyIo
  `Mydia.Torrent.read_chunk/5` NIF directly in their own process rather than
  serializing every byte-range read through the Session GenServer's mailbox.
  """
  def get_torrent_info(session_id) do
    with {:ok, %{pid: pid}} <- get_active_session(session_id) do
      Session.get_torrent_info(pid)
    end
  end

  @doc """
  Stops a torrent session.

  Transitions the DB row to `:cancelled` (rather than deleting it) so audit
  history is preserved. Rows already in `:completed` are left untouched.
  Best-effort removes any staged file left behind.
  """
  def stop_session(session_id) do
    SessionSupervisor.stop_session(session_id)

    case Repo.get(SessionSchema, session_id) do
      nil ->
        :ok

      %SessionSchema{state: :completed} ->
        :ok

      %SessionSchema{} = record ->
        # Best-effort: drop the staged file before flipping state so the
        # filesystem doesn't keep growing for cancelled sessions.
        if is_binary(record.staging_path) and File.exists?(record.staging_path) do
          _ = File.rm(record.staging_path)
        end

        record
        |> SessionSchema.changeset(%{state: :cancelled})
        |> Repo.update()

        :ok
    end
  end

  @doc """
  Stops every active torrent streaming session owned by the given user.

  Called by `Mydia.Accounts.delete_user/1` so the supervised Session GenServers
  for the deleted user are terminated cleanly before the DB cascade deletes
  the corresponding session rows. Without this step the GenServers run on,
  holding the librqbit handle, and `terminate/2` later fails to update a
  no-longer-existing DB row.

  Idempotent — sessions already stopped are a no-op.
  """
  def stop_user_sessions(user_id) when is_binary(user_id) do
    user_session_ids =
      Repo.all(
        from s in SessionSchema,
          where: s.user_id == ^user_id and s.state in ^@active_session_states,
          select: s.id
      )

    Enum.each(user_session_ids, &stop_session/1)
    :ok
  end

  @doc """
  Lists all active torrent streaming sessions.

  Issues a single batched query and preserves the supervisor's ordering.
  """
  def list_active_sessions do
    supervised = SessionSupervisor.list_sessions()
    session_ids = Enum.map(supervised, fn {id, _pid, _meta} -> id end)

    if session_ids == [] do
      []
    else
      sessions =
        Repo.all(
          from s in SessionSchema,
            where: s.id in ^session_ids,
            preload: [:user, :media_item, episode: :media_item]
        )

      by_id = Map.new(sessions, &{&1.id, &1})

      session_ids
      |> Enum.map(&Map.get(by_id, &1))
      |> Enum.reject(&is_nil/1)
    end
  end

  # Database Helpers

  defp create_session_record(attrs) do
    %SessionSchema{}
    |> SessionSchema.changeset(
      Map.put_new(attrs, :started_at, DateTime.utc_now() |> DateTime.truncate(:second))
    )
    |> Repo.insert()
  end
end
