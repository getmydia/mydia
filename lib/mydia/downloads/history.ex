defmodule Mydia.Downloads.History do
  @moduledoc false

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers

  use Mydia.QueryHelpers.Filterable,
    function_name: :apply_download_filters,
    filters: [
      media_item_id: :eq,
      episode_id: :eq
    ]

  alias Mydia.Repo
  alias Mydia.Downloads.ClientAdoption
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.Structs.DownloadMetadata
  alias Mydia.Downloads.Structs.EnrichedDownload
  alias Mydia.Settings
  alias Phoenix.PubSub
  require Logger

  # A record with no client fields is a grab in flight; older than this it is
  # considered a crashed/abandoned grab and derives to "failed".
  @grab_timeout_minutes 10

  ## Public Functions

  @doc """
  The grab-timeout threshold (minutes) used both to derive a stale grab's
  displayed status (see `grab_status/1`) and by `Mydia.Jobs.DownloadMonitor`
  to detect abandoned grabs to persist as failed. Single-sourced so the
  displayed and persisted thresholds never drift apart.
  """
  def grab_timeout_minutes, do: @grab_timeout_minutes

  @doc """
  Lists client-less grab records whose supervised task died before writing
  an outcome (BEAM restart, deploy) — no `download_client`/`download_client_id`,
  no `error_message`, not completed, not imported — and whose `inserted_at`
  is older than `grab_timeout_minutes/0`.

  The derived `"failed"` status from `grab_status/1` only changes what's
  *displayed*; `Download.occupying/1` keys off the persisted `error_message`,
  so without this these orphaned grabs would block re-grabs of their target
  forever. Used by `Mydia.Jobs.DownloadMonitor` to persist the failure.
  """
  def list_stale_grabs(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@grab_timeout_minutes, :minute)

    Download
    |> where([d], is_nil(d.download_client) and is_nil(d.download_client_id))
    |> where([d], is_nil(d.error_message))
    |> where([d], is_nil(d.completed_at))
    |> where([d], is_nil(d.imported_at))
    |> where([d], d.inserted_at < ^cutoff)
    |> Repo.all()
  end

  def list_downloads(opts \\ []) do
    Download
    |> apply_download_filters(opts)
    |> maybe_preload(opts[:preload])
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc """
  Counts imported downloads — the set `clear_all_completed/1` would remove.

  Used to show a scope-accurate blast radius before the user confirms a
  destructive "delete files from disk" clear.
  """
  def count_completed do
    Download
    |> where([d], not is_nil(d.imported_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  Counts the downloads still waiting on `client_name`: rows assigned to it that
  have not been imported.

  Called before deleting a download client, while that client still exists, to
  show the operator the blast radius. Deliberately not restricted to orphans,
  since a healthy in-flight download is exactly what the warning is about, but
  imported rows are excluded. Import does not delete the row (`MediaImport`
  stamps `imported_at` and leaves it, which is why `count_completed/0` exists),
  so on a mature instance import history dominates any count that includes it,
  while deleting the client does nothing at all to that history: it never
  reaches the `missing` filter, never gets an error, and never gets tagged.
  """
  @spec count_downloads_for_client(String.t()) :: non_neg_integer()
  def count_downloads_for_client(client_name) do
    Download
    |> where([d], d.download_client == ^client_name)
    |> where([d], is_nil(d.imported_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  Groups orphaned downloads by the client they reference, ordered by name.

  The ordering is load-bearing rather than cosmetic: the Issues tab derives a
  DOM id per group, and an unordered result could reassign those ids between
  renders, which is exactly what LiveView's id-keyed patching must not see.

  An orphan is a row tagged `import_failure_reason == "no_client"`, written
  either by `DownloadMonitor.handle_missing/1` for a download still in flight
  or by `MediaImport` for one that died at import. The Issues tab renders one
  bulk-clear banner per group.
  """
  @spec removed_client_groups() :: [%{download_client: String.t(), count: non_neg_integer()}]
  def removed_client_groups do
    Download
    |> where([d], d.import_failure_reason == "no_client" and not is_nil(d.download_client))
    |> group_by([d], d.download_client)
    |> order_by([d], asc: d.download_client)
    |> select([d], %{download_client: d.download_client, count: count(d.id)})
    |> Repo.all()
  end

  @doc """
  Deletes the orphaned downloads referencing `client_name`.

  Scoped on purpose, unlike `dismiss_all_cancelled/0`, which deletes every
  errored row in the Issues tab. No attempt is made to remove anything from
  the download client: that client is precisely what no longer exists.
  """
  @spec clear_downloads_for_removed_client(String.t()) :: {non_neg_integer(), nil | [term()]}
  def clear_downloads_for_removed_client(client_name) do
    Download
    |> where([d], d.download_client == ^client_name and d.import_failure_reason == "no_client")
    |> Repo.delete_all()
  end

  def list_downloads_with_status(opts \\ []) do
    # Get all download records from database
    # Preload episode.media_item to get parent show info for episode downloads
    downloads = list_downloads(preload: [:media_item, episode: :media_item])

    # Every configured client, including disabled ones. Disabled clients are
    # never polled, but we still need their names to tell "disabled" apart
    # from "deleted" when classifying a download's client.
    all_configured = Settings.list_download_client_configs()
    clients = Enum.filter(all_configured, & &1.enabled)

    configured_names = MapSet.new(all_configured, & &1.name)
    client_types = Map.new(all_configured, &{&1.name, &1.type})

    if all_configured == [] do
      Logger.warning("No download clients configured")

      # No clients at all means every download that names one references a
      # client that is gone: for a self-hosted operator with a single client,
      # deleting it IS this scenario, not an edge case of it. Classify those
      # rows :removed so the honest copy and the `no_client` tag still apply.
      # A download with no `download_client` at all has nothing to classify
      # against, so `client_config_state` stays nil for it, per
      # EnrichedDownload's contract. Polling and `apply_status_filters` stay
      # skipped either way — there is nothing to poll.
      Enum.map(downloads, fn download ->
        enriched = enrich_download_with_empty_status(download)

        if is_nil(download.download_client) do
          enriched
        else
          with_client_state(enriched, :removed)
        end
      end)
    else
      # Get status from all clients
      client_statuses = fetch_all_client_statuses(clients, downloads)

      # Enrich downloads with client status
      downloads
      |> Enum.map(
        &enrich_download_with_status(&1, client_statuses, client_types, configured_names)
      )
      |> apply_status_filters(opts[:filter] || :all)
    end
  end

  def get_download!(id, opts \\ []) do
    Download
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  def create_download(attrs \\ %{}) do
    result =
      %Download{}
      |> Download.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, download} ->
        broadcast_download_update(download.id)
        {:ok, download}

      error ->
        error
    end
  end

  def update_download(%Download{} = download, attrs) do
    result =
      download
      |> Download.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated_download} ->
        broadcast_download_update(updated_download.id)
        {:ok, updated_download}

      error ->
        error
    end
  end

  @doc """
  Lists failed downloads classified as a path-mapping mismatch whose reported
  path is at or under `remote_prefix`. Used to fan out an applied mapping to
  every affected download.
  """
  def list_path_mapping_mismatches_under_prefix(remote_prefix) when is_binary(remote_prefix) do
    like_pattern = remote_prefix <> "/%"

    Download
    |> where([d], not is_nil(d.import_failed_at))
    |> where([d], d.import_failure_reason == "path_mapping_mismatch")
    |> where(
      [d],
      d.import_reported_path == ^remote_prefix or like(d.import_reported_path, ^like_pattern)
    )
    |> Repo.all()
  end

  @doc """
  Lists the distinct reported paths of downloads that failed import because of
  a path-mapping mismatch. These are the remote paths Mydia saw but could not
  translate, making them the most useful suggestions for a `remote_prefix`.
  """
  def list_failed_remote_paths do
    Download
    |> where([d], not is_nil(d.import_failed_at))
    |> where([d], d.import_failure_reason == "path_mapping_mismatch")
    |> where([d], not is_nil(d.import_reported_path))
    |> select([d], d.import_reported_path)
    |> distinct(true)
    |> Repo.all()
  end

  def mark_download_completed(%Download{} = download) do
    download
    |> Download.changeset(%{completed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def mark_download_failed(%Download{} = download, error_message) do
    download
    |> Download.changeset(%{error_message: error_message})
    |> Repo.update()
  end

  def delete_download(%Download{} = download) do
    result = Repo.delete(download)

    case result do
      {:ok, deleted_download} ->
        broadcast_download_update(deleted_download.id)
        {:ok, deleted_download}

      error ->
        error
    end
  end

  def change_download(%Download{} = download, attrs \\ %{}) do
    Download.changeset(download, attrs)
  end

  def list_active_downloads(opts \\ []) do
    list_downloads_with_status(Keyword.put(opts, :filter, :active))
  end

  def count_active_downloads do
    list_active_downloads()
    |> length()
  end

  def list_stuck_downloads(opts \\ []) do
    threshold_minutes = Keyword.get(opts, :threshold_minutes, 60)
    threshold_time = DateTime.add(DateTime.utc_now(), -threshold_minutes, :minute)

    Download
    |> where([d], not is_nil(d.completed_at))
    |> where([d], is_nil(d.imported_at))
    |> where([d], is_nil(d.import_failed_at))
    |> where([d], d.completed_at < ^threshold_time)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  def broadcast_download_update(download_id) do
    PubSub.broadcast(Mydia.PubSub, "downloads", {:download_updated, download_id})
  end

  ## Private Functions - Client Status Fetching

  defp fetch_all_client_statuses(clients, downloads) do
    # Fetch torrents from all clients concurrently. We deliberately distinguish
    # between two outcomes that previously collapsed into "empty list":
    #
    #   - {:reachable, torrents_map} — the client answered, here are its torrents
    #   - :unreachable                — the client errored; we don't know its state
    #
    # The downstream classifier MUST NOT mark a download "missing" just because
    # its client was unreachable, otherwise a brief client restart flags every
    # active download as failed.
    #
    # We pre-group the loaded downloads by `download_client` name and forward
    # the per-client map (keyed by `download_client_id`) to each adapter via
    # `opts[:downloads]`. Adapters that don't need it ignore the opt; the
    # debrid adapter consumes it to look up the Mydia `Download` row for the
    # R8 metadata merge without performing DB queries inside the behaviour
    # callback.
    downloads_by_client = group_downloads_by_client(downloads)

    clients
    |> Task.async_stream(
      fn client_config ->
        adapter = Client.Registry.lookup(client_config.type)
        config = config_to_map(client_config)
        client_downloads = Map.get(downloads_by_client, client_config.name, %{})

        try do
          case Client.list_torrents(adapter, config, downloads: client_downloads) do
            {:ok, torrents} ->
              torrents_map =
                torrents
                |> Enum.map(fn torrent -> {torrent.id, torrent} end)
                |> Map.new()

              {client_config.name, {:reachable, torrents_map}}

            {:error, error} ->
              Logger.warning(
                "Failed to fetch torrents from #{client_config.name}: #{inspect(error)}"
              )

              {client_config.name, :unreachable}
          end
        rescue
          # A buggy or mis-registered adapter (e.g. a module that doesn't
          # implement list_torrents/2) must not crash the caller — that would
          # take down the whole Downloads LiveView for every other client too.
          # Degrade to :unreachable, same as an explicit {:error, _}.
          exception ->
            Logger.error(
              "Adapter #{inspect(adapter)} for client #{client_config.name} " <>
                "(type=#{client_config.type}) raised: #{Exception.message(exception)}"
            )

            {client_config.name, :unreachable}
        end
      end,
      timeout: :infinity,
      max_concurrency: 10
    )
    |> Enum.reduce(%{}, fn
      {:ok, {client_name, result}}, acc -> Map.put(acc, client_name, result)
      _, acc -> acc
    end)
  end

  defp group_downloads_by_client(downloads) do
    Enum.reduce(downloads, %{}, fn download, acc ->
      case {download.download_client, download.download_client_id} do
        {nil, _} ->
          acc

        {_, nil} ->
          acc

        {client_name, client_id} ->
          Map.update(acc, client_name, %{client_id => download}, fn existing ->
            Map.put(existing, client_id, download)
          end)
      end
    end)
  end

  defp enrich_download_with_status(download, client_statuses, client_types, configured_names) do
    case classify_client(download.download_client, client_statuses, configured_names) do
      {:reachable, torrents_map} ->
        case Map.get(torrents_map, download.download_client_id) do
          nil ->
            # Client confirmed it doesn't have this torrent — genuinely missing.
            download
            |> enrich_download_with_empty_status(false)
            |> with_client_state(:present)

          torrent_status ->
            download
            |> enrich_download_with_torrent_status(torrent_status)
            |> with_client_state(:present)
            |> heal_own_client()
        end

      :unreachable ->
        # Client is misbehaving (down, restarting, network blip). We can't tell
        # whether the torrent is there — DO NOT mark missing. Surface status as
        # "unknown" so DownloadMonitor's missing-handler skips it this cycle.
        download
        |> enrich_download_with_unknown_status()
        |> with_client_state(:present)

      :no_client_assigned ->
        # A grab record that never reached a client. `list_stale_grabs/1`
        # owns these; classification has nothing to say about them.
        enrich_download_with_empty_status(download)

      config_state when config_state in [:disabled, :removed] ->
        adopt_or_orphan(download, client_statuses, client_types, config_state)
    end
  end

  # Distinguishes the three ways a download's client can fail to appear in the
  # poll results. `:removed` and `:disabled` used to collapse into one branch,
  # which is why a disabled client produced "removed from download client".
  defp classify_client(nil, _client_statuses, _configured_names), do: :no_client_assigned

  defp classify_client(client_name, client_statuses, configured_names) do
    case Map.get(client_statuses, client_name) do
      {:reachable, _torrents} = reachable -> reachable
      :unreachable -> :unreachable
      nil -> if MapSet.member?(configured_names, client_name), do: :disabled, else: :removed
    end
  end

  # A download whose client is gone or switched off. If exactly one reachable
  # torrent client holds this torrent, the download is alive under a new client
  # name: report the real torrent status so the UI shows genuine progress, and
  # flag the candidate for `DownloadMonitor` to persist. Otherwise it is a true
  # orphan.
  defp adopt_or_orphan(download, client_statuses, client_types, config_state) do
    case ClientAdoption.find_claimant(download.download_client_id, client_statuses, client_types) do
      {:ok, claimant} ->
        {:reachable, torrents} = Map.fetch!(client_statuses, claimant)
        torrent_status = Map.fetch!(torrents, download.download_client_id)

        download
        |> enrich_download_with_torrent_status(torrent_status)
        |> with_client_state(config_state)
        |> with_adoptable_client(claimant)

      :none ->
        download
        |> enrich_download_with_empty_status()
        |> with_client_state(config_state)
    end
  end

  defp with_client_state(%EnrichedDownload{} = enriched, config_state) do
    %{enriched | client_config_state: config_state}
  end

  defp with_adoptable_client(%EnrichedDownload{} = enriched, claimant) do
    %{enriched | adoptable_client: claimant}
  end

  # The download's own client answered and still holds the torrent, so whatever
  # took the client away is over: it was re-enabled, or deleted and re-added
  # under the same name. Both are what Mydia's own copy tells the operator to
  # do (the disabled-client message says "re-enable the client", the admin
  # delete modal says re-adding picks the downloads back up).
  #
  # Nothing else clears orphan state on that route, so without this the row
  # keeps a false error message forever, stays out of `Download.occupying/1`,
  # and keeps its group in the Issues-tab banner, whose "Clear them" button
  # would delete the record of a download that is visibly running on the Queue
  # tab. Naming the row's own client as the adoption candidate routes the heal
  # through `DownloadMonitor.adopt_download/1`: same writer, same clearing
  # rule, and its `download_client` write is a no-op.
  defp heal_own_client(%EnrichedDownload{} = enriched) do
    if ClientAdoption.orphan_state?(enriched.import_failure_reason, enriched.error_message) do
      with_adoptable_client(enriched, enriched.download_client)
    else
      enriched
    end
  end

  defp enrich_download_with_torrent_status(download, torrent_status) do
    metadata = DownloadMetadata.from_map(download.metadata)

    EnrichedDownload.new(%{
      id: download.id,
      media_item_id: download.media_item_id,
      episode_id: download.episode_id,
      media_item: download.media_item,
      episode: download.episode,
      title: download.title,
      indexer: download.indexer,
      download_url: download.download_url,
      download_client: download.download_client,
      download_client_id: download.download_client_id,
      metadata: download.metadata,
      match_status: download.match_status,
      inserted_at: download.inserted_at,
      status: status_from_torrent_state(torrent_status.state),
      progress: torrent_status.progress,
      download_speed: torrent_status.download_speed,
      upload_speed: torrent_status.upload_speed,
      eta: torrent_status.eta,
      size: torrent_status.size,
      downloaded: torrent_status.downloaded,
      uploaded: torrent_status.uploaded,
      ratio: torrent_status.ratio,
      seeders: if(metadata, do: metadata.seeders, else: nil),
      leechers: if(metadata, do: metadata.leechers, else: nil),
      save_path: torrent_status.save_path,
      completed_at: download.completed_at || torrent_status.completed_at,
      error_message: download.error_message,
      client_failure_category: torrent_status.failure_category,
      client_error_detail: torrent_status.failure_detail,
      db_completed_at: download.completed_at,
      imported_at: download.imported_at,
      import_retry_count: download.import_retry_count,
      import_last_error: download.import_last_error,
      import_failure_reason: download.import_failure_reason,
      import_reported_path: download.import_reported_path,
      import_next_retry_at: download.import_next_retry_at,
      import_failed_at: download.import_failed_at,
      last_progress_at: download.last_progress_at,
      last_known_bytes: download.last_known_bytes,
      last_observed_at: download.last_observed_at,
      stalled_since: download.stalled_since,
      in_client?: true
    })
  end

  defp enrich_download_with_unknown_status(download) do
    metadata = DownloadMetadata.from_map(download.metadata)

    EnrichedDownload.new(%{
      id: download.id,
      media_item_id: download.media_item_id,
      episode_id: download.episode_id,
      media_item: download.media_item,
      episode: download.episode,
      title: download.title,
      indexer: download.indexer,
      download_url: download.download_url,
      download_client: download.download_client,
      download_client_id: download.download_client_id,
      metadata: download.metadata,
      match_status: download.match_status,
      inserted_at: download.inserted_at,
      # "unknown" intentionally avoids the "missing" / "failed" classifications.
      status: "unknown",
      progress: if(download.completed_at, do: 100.0, else: 0.0),
      download_speed: 0,
      upload_speed: 0,
      eta: nil,
      size: if(metadata, do: metadata.size, else: 0),
      downloaded: 0,
      uploaded: 0,
      ratio: 0.0,
      seeders: nil,
      leechers: nil,
      save_path: nil,
      completed_at: download.completed_at,
      error_message: download.error_message,
      db_completed_at: download.completed_at,
      imported_at: download.imported_at,
      import_retry_count: download.import_retry_count,
      import_last_error: download.import_last_error,
      import_failure_reason: download.import_failure_reason,
      import_reported_path: download.import_reported_path,
      import_next_retry_at: download.import_next_retry_at,
      import_failed_at: download.import_failed_at,
      last_progress_at: download.last_progress_at,
      last_known_bytes: download.last_known_bytes,
      # Carry the persisted stall state through an outage. The soft-stall badge
      # itself is gated on status == "downloading", so it isn't shown while the
      # client is unreachable (status "unknown"); preserving these fields keeps
      # the state intact for clearing/recovery once the client is reachable again.
      last_observed_at: download.last_observed_at,
      stalled_since: download.stalled_since,
      # Client unreachable — presence indeterminate.
      in_client?: nil
    })
  end

  defp enrich_download_with_empty_status(download, in_client? \\ nil) do
    # Download exists in DB but not in client
    # Could be completed and removed, or manually deleted from client
    status =
      cond do
        download.imported_at -> "imported"
        download.completed_at -> "completed"
        download.error_message -> "failed"
        pending_grab?(download) -> grab_status(download)
        true -> "missing"
      end

    # A stale grab has no persisted error_message; surface an implied reason.
    error_message =
      case {download.error_message, status} do
        {nil, "failed"} -> "Grab timed out"
        {message, _} -> message
      end

    # Convert metadata map to struct for type-safe access
    metadata = DownloadMetadata.from_map(download.metadata)

    EnrichedDownload.new(%{
      id: download.id,
      media_item_id: download.media_item_id,
      episode_id: download.episode_id,
      media_item: download.media_item,
      episode: download.episode,
      title: download.title,
      indexer: download.indexer,
      download_url: download.download_url,
      download_client: download.download_client,
      download_client_id: download.download_client_id,
      metadata: download.metadata,
      match_status: download.match_status,
      inserted_at: download.inserted_at,
      status: status,
      progress: if(download.completed_at, do: 100.0, else: 0.0),
      download_speed: 0,
      upload_speed: 0,
      eta: nil,
      size: if(metadata, do: metadata.size, else: 0),
      downloaded: 0,
      uploaded: 0,
      ratio: 0.0,
      seeders: nil,
      leechers: nil,
      save_path: nil,
      completed_at: download.completed_at,
      error_message: error_message,
      # Preserve database completed_at for tracking if we've already processed it
      db_completed_at: download.completed_at,
      imported_at: download.imported_at,
      import_retry_count: download.import_retry_count,
      import_last_error: download.import_last_error,
      import_failure_reason: download.import_failure_reason,
      import_reported_path: download.import_reported_path,
      import_next_retry_at: download.import_next_retry_at,
      import_failed_at: download.import_failed_at,
      last_progress_at: download.last_progress_at,
      last_known_bytes: download.last_known_bytes,
      last_observed_at: download.last_observed_at,
      stalled_since: download.stalled_since,
      in_client?: in_client?
    })
  end

  # No client assignment at all — the grab pipeline hasn't handed this record
  # to a download client yet (or died before it could).
  defp pending_grab?(download) do
    is_nil(download.download_client) and is_nil(download.download_client_id)
  end

  defp grab_status(download) do
    cutoff = DateTime.add(DateTime.utc_now(), -@grab_timeout_minutes, :minute)

    if DateTime.compare(download.inserted_at, cutoff) == :gt do
      "grabbing"
    else
      "failed"
    end
  end

  defp status_from_torrent_state(state) do
    case state do
      :downloading -> "downloading"
      :seeding -> "seeding"
      :completed -> "completed"
      :paused -> "paused"
      :checking -> "checking"
      :queued -> "queued"
      :error -> "failed"
      _ -> "unknown"
    end
  end

  defp apply_status_filters(downloads, :all), do: downloads

  defp apply_status_filters(downloads, :active) do
    Enum.filter(downloads, fn d ->
      # Active downloads are those that haven't been imported yet
      # and are currently downloading, seeding, checking, paused, or queued.
      # `queued` covers the debrid lifecycle phases where the provider is
      # waiting on the swarm or Mydia's local fetcher hasn't claimed the
      # ready job yet — without this they'd vanish from the queue tab.
      is_nil(d.imported_at) and
        d.status in ["downloading", "seeding", "checking", "paused", "queued", "grabbing"]
    end)
  end

  defp apply_status_filters(downloads, :completed) do
    Enum.filter(downloads, &(&1.status == "completed"))
  end

  # Filter for imported downloads (shown in Completed tab)
  # These are downloads that have been successfully imported to the library
  # but may still be seeding in the download client
  defp apply_status_filters(downloads, :imported) do
    Enum.filter(downloads, fn d ->
      not is_nil(d.imported_at)
    end)
  end

  defp apply_status_filters(downloads, :failed) do
    Enum.filter(downloads, fn d ->
      # Show downloads that failed in the client OR have import failures.
      # Exclude unresolved_files, which has its own section.
      (d.status in ["failed", "missing"] || not is_nil(d.import_failed_at)) and
        d.match_status != "unresolved_files"
    end)
  end

  defp apply_status_filters(downloads, :unresolved_files) do
    Enum.filter(downloads, fn d ->
      d.match_status == "unresolved_files"
    end)
  end

  defp config_to_map(config) do
    %{
      type: config.type,
      host: config.host,
      port: config.port,
      use_ssl: config.use_ssl,
      username: config.username,
      password: config.password,
      url_base: config.url_base,
      api_key: config.api_key,
      connection_settings: config.connection_settings || %{},
      options: config.connection_settings || %{}
    }
  end
end
