defmodule Mydia.Downloads.Queue.Lifecycle do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Mydia.Repo
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.History
  alias Mydia.Downloads.StallDetector
  alias Mydia.Indexers.SearchResult
  alias Mydia.Media.Episode
  alias Mydia.Events
  alias Mydia.Downloads.Queue.{ClientSelection, Duplicates}
  require Logger

  @doc """
  Drops episodes already covered by an active season-pack download.

  A season-pack download carries `media_item_id` plus `metadata.season_pack`
  and **no** `episode_id`, so any query that excludes on `episode_id` alone
  cannot see it - including the `Queue.Duplicates.check_for_active_download/4`
  episode arm, which is why an individual grab for an episode inside an in-flight
  pack succeeds. Both the missing-file search path
  (`Mydia.Jobs.TVShowSearch`) and the upgrade eligibility query
  (`Mydia.Upgrades.eligible_episodes/1`) filter through here so the two cannot
  drift apart.

  Matched by `{media_item_id, season_number}` on downloads that are still
  occupying their target (see `Mydia.Downloads.Download.occupying/1`).
  """
  @spec reject_episodes_in_active_season_packs([Episode.t()]) :: [Episode.t()]
  def reject_episodes_in_active_season_packs([]), do: []

  def reject_episodes_in_active_season_packs(episodes) when is_list(episodes) do
    media_item_ids =
      episodes
      |> Enum.map(& &1.media_item_id)
      |> Enum.uniq()

    covered =
      Download.occupying()
      |> where([d], d.media_item_id in ^media_item_ids)
      |> where(^Mydia.DB.json_is_true(:metadata, "$.season_pack"))
      |> select([d], %{media_item_id: d.media_item_id, metadata: d.metadata})
      |> Repo.all()
      |> Enum.reduce(MapSet.new(), fn
        %{media_item_id: mid, metadata: %{"season_number" => sn}}, acc when is_integer(sn) ->
          MapSet.put(acc, {mid, sn})

        _, acc ->
          acc
      end)

    Enum.reject(episodes, fn episode ->
      MapSet.member?(covered, {episode.media_item_id, episode.season_number})
    end)
  end

  def initiate_download(%SearchResult{} = search_result, opts \\ []) do
    # Normalize metadata: callers (e.g. TVShowSearch) may pass a plain map.
    # Coerce to %SearchResultMetadata{} so downstream pattern matches and
    # persistence in create_download_record/4 work uniformly.
    search_result = Duplicates.normalize_search_result_metadata(search_result)

    # Use protocol from search result
    download_type = search_result.download_protocol
    Logger.debug("Download protocol: #{inspect(download_type)} for #{search_result.title}")

    opts = Keyword.put(opts, :download_type, download_type)

    with :ok <- Duplicates.check_for_duplicate_download(search_result, opts),
         {:ok, client_config, client_id, detected_type} <-
           ClientSelection.select_and_add_to_client(search_result, opts),
         {:ok, download} <-
           ClientSelection.create_download_record_with_retry(
             search_result,
             client_config,
             client_id,
             opts
           ) do
      # Use detected type as fallback if protocol wasn't set
      final_type = download_type || detected_type

      Logger.info(
        "Final download type: #{inspect(final_type)} (original: #{inspect(download_type)}, detected: #{inspect(detected_type)})"
      )

      # Track event
      actor_type = Keyword.get(opts, :actor_type, :system)
      actor_id = Keyword.get(opts, :actor_id, "downloads_context")

      # Get media_item for context if available (preloaded on download)
      download_with_media = Repo.preload(download, :media_item)

      Events.download_initiated(download_with_media, actor_type, actor_id,
        media_item: download_with_media.media_item
      )

      {:ok, download}
    else
      {:error, reason} = error ->
        Logger.warning("Failed to initiate download: #{inspect(reason)}")
        error
    end
  end

  def cancel_download(%Download{} = download, opts \\ []) do
    with {:ok, client_config} <- ClientSelection.find_client_config(download.download_client),
         {:ok, adapter} <- ClientSelection.get_adapter_for_client(client_config),
         client_map_config = ClientSelection.config_to_map(client_config),
         :ok <-
           Client.remove_download(adapter, client_map_config, download.download_client_id, opts),
         {:ok, _deleted} <- History.delete_download(download) do
      blacklist_if_stalled(download)

      # Track event
      actor_type = Keyword.get(opts, :actor_type, :user)
      actor_id = Keyword.get(opts, :actor_id, "unknown")

      Events.download_cancelled(download, actor_type, actor_id)

      {:ok, download}
    else
      {:error, reason} ->
        Logger.warning("Failed to cancel download: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Rejects a release the operator has judged unusable.

  Best-effort blacklists `(indexer, guid)` when a key can be extracted, removes
  the torrent and its data from the client (best effort), deletes the download
  row, and queues a fresh search for the bound episode or movie.

  A download with no blacklist key, or whose blacklist write fails, is still
  cleared — it is simply not recorded. The torrent is dead either way.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :user
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
    - `:failure_reason` - Blacklist reason slug - defaults to "rejected_by_user"
    - `:ttl_days` - Days until the blacklist entry expires - defaults to the
      configured `release_blacklist_default_ttl_days` (30)
    - `:event` - `:cancelled` (default) emits `download.cancelled`; `:none`
      emits nothing, for callers that emit their own more specific event
  """
  @spec reject_release(Download.t(), keyword()) :: {:ok, :rejected} | {:error, term()}
  def reject_release(%Download{} = download, opts \\ []) do
    blacklist_release(download, opts)
    finish_reject(download, opts)
  end

  # Best effort, and deliberately so. A release we cannot key (no indexer or
  # guid — externally-adopted torrents, manual grabs) or whose blacklist write
  # fails is still a dead download: clearing it matters more than recording
  # why. Leaving the torrent running because the bookkeeping failed is the
  # exact bug this path exists to fix.
  @doc false
  # Public for Mydia.Downloads.Removal.request_reject/2, which blacklists at
  # click time and leaves the client call to a job.
  def blacklist_release(%Download{} = download, opts) do
    with {:ok, indexer, guid} <- Blacklists.extract_key(download),
         {:ok, _row} <-
           Blacklists.add(
             indexer,
             guid,
             download.title || "Unknown release",
             Keyword.get(opts, :failure_reason, "rejected_by_user"),
             [info_hash: Blacklists.download_info_hash(download)] ++ blacklist_opts(opts)
           ) do
      :ok
    else
      # Having no release key is an ordinary shape, not a problem: externally
      # adopted torrents and manual grabs never had one. Logging it at warning
      # would make routine operator rejections look like faults.
      {:error, reason} when reason in [:no_indexer, :no_guid] ->
        Logger.debug("Rejecting a release with no blacklist key",
          download_id: download.id,
          reason: inspect(reason)
        )

        :ok

      # A write that actually failed is worth surfacing: the release will not be
      # filtered out of the next search.
      {:error, reason} ->
        Logger.warning("Rejecting release but the blacklist write failed",
          download_id: download.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Whether cancelling `download` now blacklists its release: it is stalled
  right now (see `StallDetector.soft_stalled?/1`) and carries the
  `(indexer, guid)` key a ban is recorded under. A download with no key, such
  as an adopted torrent or a manual grab, is cancelled without one.
  """
  @spec cancel_bans_release?(Download.t()) :: boolean()
  def cancel_bans_release?(%Download{} = download) do
    StallDetector.soft_stalled?(download) and
      match?({:ok, _indexer, _guid}, Blacklists.extract_key(download))
  end

  @doc """
  Blacklists the release when `cancel_bans_release?/1` returns true, and does
  nothing otherwise.

  A cancel is a plain stop, except on a stalled download: the operator has
  looked at a torrent that is not moving and given up on it, the same judgement
  as a reject, so the release stays out of later searches for the default TTL.
  No replacement search is queued. That stays Reject's job.
  """
  @spec blacklist_if_stalled(Download.t()) :: :ok
  def blacklist_if_stalled(%Download{} = download) do
    if cancel_bans_release?(download) do
      blacklist_release(download, failure_reason: "cancelled_stalled")
    else
      :ok
    end
  end

  # Only forward :ttl_days when the caller set it, so Blacklists.add/5 keeps
  # applying its own configured default for every existing caller.
  defp blacklist_opts(opts) do
    case Keyword.get(opts, :ttl_days) do
      nil -> []
      days -> [ttl_days: days]
    end
  end

  # Everything after the blacklist decision: clear the torrent, drop the row,
  # queue a replacement, and (optionally) announce it.
  defp finish_reject(%Download{} = download, opts) do
    # Computed before deletion: it reads through the media_item association.
    search = ClientSelection.replacement_search(download)

    remove_from_client(download)

    case History.delete_download(download) do
      {:ok, _deleted} ->
        ClientSelection.enqueue_search(search)
        emit_reject_event(download, opts)

        {:ok, :rejected}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A caller that emits its own, more specific event passes `event: :none` so
  # one give-up does not produce two entries in the activity feed.
  defp emit_reject_event(download, opts) do
    case Keyword.get(opts, :event, :cancelled) do
      :none ->
        :ok

      :cancelled ->
        Events.download_cancelled(
          download,
          Keyword.get(opts, :actor_type, :user),
          Keyword.get(opts, :actor_id, "unknown")
        )
    end
  end

  def pause_download(%Download{} = download, opts \\ []) do
    with {:ok, client_config} <- ClientSelection.find_client_config(download.download_client),
         {:ok, adapter} <- ClientSelection.get_adapter_for_client(client_config),
         client_map_config = ClientSelection.config_to_map(client_config),
         :ok <- Client.pause_torrent(adapter, client_map_config, download.download_client_id) do
      # Track event
      actor_type = Keyword.get(opts, :actor_type, :user)
      actor_id = Keyword.get(opts, :actor_id, "unknown")

      Events.download_paused(download, actor_type, actor_id)

      History.broadcast_download_update(download.id)
      {:ok, download}
    else
      {:error, reason} ->
        Logger.warning("Failed to pause download in client: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def resume_download(%Download{} = download, opts \\ []) do
    with {:ok, client_config} <- ClientSelection.find_client_config(download.download_client),
         {:ok, adapter} <- ClientSelection.get_adapter_for_client(client_config),
         client_map_config = ClientSelection.config_to_map(client_config),
         :ok <- Client.resume_torrent(adapter, client_map_config, download.download_client_id) do
      # Track event
      actor_type = Keyword.get(opts, :actor_type, :user)
      actor_id = Keyword.get(opts, :actor_id, "unknown")

      Events.download_resumed(download, actor_type, actor_id)

      History.broadcast_download_update(download.id)
      {:ok, download}
    else
      {:error, reason} ->
        Logger.warning("Failed to resume download in client: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def clear_completed(%Download{} = download, opts \\ []) do
    # Try to remove from client first (ignore errors as may already be removed)
    case ClientSelection.find_client_config(download.download_client) do
      {:ok, client_config} ->
        case ClientSelection.get_adapter_for_client(client_config) do
          {:ok, adapter} ->
            client_map_config = ClientSelection.config_to_map(client_config)

            # Attempt to remove from client, but don't fail if it's already gone
            case Client.remove_download(
                   adapter,
                   client_map_config,
                   download.download_client_id,
                   opts
                 ) do
              :ok ->
                Logger.info("Removed completed download from client",
                  download_id: download.id,
                  client: download.download_client
                )

              {:error, reason} ->
                Logger.debug("Could not remove from client (may already be removed)",
                  download_id: download.id,
                  reason: inspect(reason)
                )
            end

          {:error, _} ->
            Logger.debug("No adapter found for client", client: download.download_client)
        end

      {:error, _} ->
        Logger.debug("Client config not found", client: download.download_client)
    end

    # Always delete the database record
    case History.delete_download(download) do
      {:ok, deleted_download} ->
        # Track event
        actor_type = Keyword.get(opts, :actor_type, :user)
        actor_id = Keyword.get(opts, :actor_id, "unknown")

        Events.download_cleared(download, actor_type, actor_id)

        {:ok, deleted_download}

      error ->
        error
    end
  end

  def clear_all_completed(opts \\ []) do
    # Get all imported downloads
    imported_downloads =
      Download
      |> where([d], not is_nil(d.imported_at))
      |> Repo.all()

    results =
      Enum.map(imported_downloads, fn download ->
        case clear_completed(download, opts) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    {:ok, success_count}
  end

  def dismiss_download(%Download{} = download) do
    History.delete_download(download)
  end

  # Best effort: a torrent the client no longer holds must not block the reject.
  defp remove_from_client(%Download{download_client: nil}), do: :ok
  defp remove_from_client(%Download{download_client_id: nil}), do: :ok

  defp remove_from_client(download) do
    with {:ok, client_config} <- ClientSelection.find_client_config(download.download_client),
         {:ok, adapter} <- ClientSelection.get_adapter_for_client(client_config) do
      Client.remove_download(
        adapter,
        ClientSelection.config_to_map(client_config),
        download.download_client_id,
        delete_files: true
      )
    end

    :ok
  rescue
    exception ->
      Logger.warning("Could not remove rejected release from client",
        download_id: download.id,
        error: Exception.message(exception)
      )

      :ok
  catch
    # The debrid adapter's remove_torrent/3 terminates any running Fetcher
    # first via DynamicSupervisor.terminate_child/2 — a GenServer.call that
    # emits an :exit signal (not an Elixir exception) if the supervisor isn't
    # alive, same hazard documented on
    # Mydia.Downloads.Client.Debrid.RateLimiter.acquire/3. `rescue` alone
    # would not catch it, and a client that will not answer must not block
    # rejecting a bad release.
    :exit, reason ->
      Logger.warning("Could not remove rejected release from client (process exit)",
        download_id: download.id,
        reason: inspect(reason)
      )

      :ok
  end
end
