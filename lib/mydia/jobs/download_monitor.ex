defmodule Mydia.Jobs.DownloadMonitor do
  @moduledoc """
  Background job for monitoring downloads and handling completion.

  With download clients as the source of truth, this job now focuses on:
  - Detecting completed downloads in clients
  - Marking downloads as completed in the database
  - Triggering media import jobs for completed downloads
  - Recording errors for failed downloads
  - Flagging downloads that were removed from clients

  ## Missing Download Detection

  When a download is manually removed from a download client (e.g., Transmission),
  the job will detect this and mark the download as "missing" with an error message.
  This preserves the download in the Issues tab so users can investigate why the
  download was removed before import completed. Users can manually delete from
  the Issues tab if desired.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    # Prevent two DownloadMonitor passes from running back-to-back — the cron
    # plugin and the adaptive fast-followup chain (see end of `perform/1`)
    # could otherwise stack up if a tick is slower than the followup interval.
    # The period covers ~one cron interval.
    #
    # `:incomplete` is Oban's named group for every pre-completion state
    # (`:suspended, :available, :scheduled, :executing, :retryable`) — the
    # form Oban 2.23 itself recommends ("use a unique group like :incomplete")
    # instead of a literal `:states` list, which now warns at compile time
    # (a hard failure under --warnings-as-errors) when it's missing a state.
    #
    # A plain cron tick and a fast-followup insert are never each other's
    # duplicate regardless of state: `:fields` isn't overridden here, so
    # uniqueness is keyed on the default `[:args, :queue, :worker]`, and
    # `maybe_schedule_fast_followup/2` inserts with a distinct
    # `"fast_chain_position"` arg the parent tick's own args don't carry (see
    # DownloadMonitorFastFollowupTest, which asserts a followup inserted while
    # its parent is still :executing is not flagged as a conflict). So
    # `:executing` doesn't need excluding for the chain to work.
    #
    # `:incomplete` does introduce one real behavior change over the previous
    # narrower list: a cron tick currently sitting in `:retryable` (backing
    # off after a failure) now blocks a new cron-triggered insert with the
    # same (empty) args, where it previously didn't. That's the intended
    # effect — two monitor passes racing is exactly what this config exists
    # to prevent — and Oban still retries the backed-off job on its own
    # schedule once the backoff elapses.
    unique: [period: 120, states: :incomplete]

  require Logger
  alias Mydia.Downloads
  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.Client.FailureCategory
  alias Mydia.Downloads.StallDetector
  alias Mydia.Downloads.UntrackedMatcher
  alias Mydia.Events
  alias Mydia.Settings

  # Fallback grace window (minutes) when a download has no resolvable client
  # config. The DB schema's default is also 60; this just guards against a nil.
  @default_grace_minutes 60

  # A soft-stall escalates to a terminal failure only after it has persisted for
  # `grace_minutes × @stall_escalation_multiplier` (default 60 × 3 = 180 min).
  # A dedicated per-client knob is deferred.
  @stall_escalation_multiplier 3

  # An observation gap larger than this resets the stall clock instead of
  # accruing stall time — covers client outages, Mydia restarts, and torrents
  # that sat paused/queued. 360s is ~3 cron cycles at the 120s DownloadMonitor
  # interval; the 15s adaptive fast-followup chain keeps live polling well
  # inside this window.
  @observation_gap_seconds 360

  # Adaptive polling: when downloads are actively running, the cron plugin's
  # 2-minute interval is too slow — completed downloads land in the library
  # 0–120s after the client says so. To shorten that gap without configuring
  # tighter cron (and without asking the operator to wire up webhooks from
  # their downloader, which would require them to know what URL their Mydia
  # is reachable at from the downloader's network), each cron-triggered
  # perform/1 seeds a chain of `@fast_followup_steps` follow-up jobs spaced
  # `@fast_followup_interval_seconds` apart. The chain length × interval
  # roughly equals the cron interval so adaptive polling fills the gap with
  # no overlap. The chain self-terminates the moment no active downloads
  # remain, returning the worker to pure cron cadence.
  @fast_followup_interval_seconds 15
  @fast_followup_steps 7

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Starting download completion monitoring", args: args)

    # Allow tests to inject a deterministic clock via job args (`"now" => iso8601`).
    now = resolve_now(args)

    # Get all downloads with their real-time status from clients
    downloads = Downloads.list_downloads_with_status(filter: :all)

    # Re-adopt downloads whose client was renamed, deleted, or disabled but
    # whose torrent is still sitting in exactly one other configured client.
    # This is the only writer for adoptions: `list_downloads_with_status/1`
    # is a read path called from LiveViews and must stay pure.
    downloads
    |> Enum.filter(&(&1.adoptable_client != nil))
    |> Enum.each(&adopt_download/1)

    # Find downloads that have completed or failed
    # Note: "seeding" means download is complete and now seeding (100% progress)
    # A torrent can also be paused at 100% progress (manually paused after completion)
    # We check db_completed_at to see if we've already marked it as completed in our database
    completed =
      Enum.filter(downloads, fn d ->
        is_nil(d.db_completed_at) and
          (d.status in ["completed", "seeding"] or
             (d.status == "paused" and d.progress == 100.0))
      end)

    failed = Enum.filter(downloads, &(&1.status == "failed" and is_nil(&1.error_message)))

    # Find downloads that no longer exist in any tracker
    # These are downloads that were manually removed from the client
    # Status is "missing" when download exists in DB but not in any client
    missing =
      Enum.filter(downloads, fn d ->
        d.status == "missing" and is_nil(d.db_completed_at) and is_nil(d.error_message) and
          d.match_status != "unmatched"
      end)

    # Self-heal: unmatched downloads whose torrent is no longer in any client
    # have no recovery path — they were never paired to a media_item and have
    # no destination library_path. Delete them so MediaImport stops retrying
    # forever. (Matched downloads keep going through `missing` / `failed`
    # handlers so the user can investigate them in the Issues tab.)
    unmatched_orphans =
      Enum.filter(downloads, fn d ->
        d.match_status == "unmatched" and d.in_client? == false
      end)

    # Self-heal: a grab task that died mid-flight (BEAM restart, deploy)
    # before writing an outcome leaves a client-less record with a nil
    # `error_message`. The `"failed"` status History derives for it only
    # affects what's *displayed* — Download.occupying/1 keys off the
    # persisted error_message, so an orphaned grab would block re-grabs of
    # its target forever without this. Queried directly (not from
    # `downloads`) since it's independent of client status.
    stale_grabs = Downloads.list_stale_grabs(now)

    # Active downloads we should track for stall detection. Only genuinely
    # *downloading* torrents accrue stall time — paused/queued/checking/seeding
    # are not observed, so their stale clock is neutralised by the gap reset on
    # resume. Terminal rows (import_failed_at set) stay excluded
    # so an escalated stall isn't re-evaluated; soft-stalled rows keep
    # import_failed_at nil and so remain in the set for auto-clear/escalation.
    active_for_stall_check =
      Enum.filter(downloads, fn d ->
        d.status == "downloading" and
          is_nil(d.import_failed_at) and
          is_nil(d.imported_at)
      end)

    Logger.info(
      "Found #{length(completed)} newly completed, #{length(failed)} newly failed, #{length(missing)} missing downloads, #{length(unmatched_orphans)} unmatched orphans, #{length(stale_grabs)} stale grabs, #{length(active_for_stall_check)} active for stall check"
    )

    # Handle completions
    Enum.each(completed, &handle_completion/1)

    # Handle failures
    Enum.each(failed, &handle_failure/1)

    # Handle missing downloads
    Enum.each(missing, &handle_missing/1)

    # Self-heal unmatched orphans (delete; never imported, never will be)
    Enum.each(unmatched_orphans, &handle_unmatched_orphan/1)

    # Self-heal abandoned grabs (persist the timeout so occupancy is released)
    Enum.each(stale_grabs, &handle_stale_grab/1)

    # Track progress / flag stalled downloads. Grace minutes are read from each
    # download's configured client (DB or runtime config) — cached per poll.
    grace_map = build_grace_map()
    stalled_count = check_progress(active_for_stall_check, grace_map, now)

    # Find and match untracked torrents (manually added to clients)
    untracked_downloads = UntrackedMatcher.find_and_match_untracked()
    Logger.info("Matched #{length(untracked_downloads)} untracked torrent(s) to library items")

    # Detect stuck downloads (completed but never imported for >1 hour)
    stuck = Downloads.list_stuck_downloads(preload: [:media_item])
    Logger.info("Found #{length(stuck)} stuck downloads")
    Enum.each(stuck, &handle_stuck/1)

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info("Download monitoring completed",
      duration_ms: duration,
      completed_count: length(completed),
      failed_count: length(failed),
      missing_count: length(missing),
      unmatched_orphans_cleaned: length(unmatched_orphans),
      stale_grabs_cleaned: length(stale_grabs),
      stalled_count: stalled_count,
      stuck_count: length(stuck),
      untracked_matched: length(untracked_downloads)
    )

    maybe_schedule_fast_followup(active_for_stall_check, args)

    :ok
  end

  # Schedules the next link in the adaptive fast-followup chain if there's
  # still active work and we haven't exhausted the chain. The chain bounds
  # itself by `chain_position`; the cron-seeded run starts at 0.
  defp maybe_schedule_fast_followup([], _args), do: :ok

  defp maybe_schedule_fast_followup(_active, args) do
    position = Map.get(args, "fast_chain_position", 0)

    if position < @fast_followup_steps do
      try do
        %{"fast_chain_position" => position + 1}
        |> __MODULE__.new(schedule_in: @fast_followup_interval_seconds)
        |> Oban.insert()
      rescue
        # Oban isn't running (test mode with `engine: false`, or supervisor
        # not yet up). Adaptive polling is opportunistic — the next cron
        # tick will pick up the work even if a follow-up couldn't be queued.
        RuntimeError -> :ok
      else
        # Conflict via the unique constraint means a follow-up is already
        # queued; not a failure.
        _result -> :ok
      end
    else
      :ok
    end
  end

  ## Private Functions

  defp handle_completion(download_map) do
    Logger.info("Handling completed download",
      download_id: download_map.id,
      title: download_map.title,
      save_path: download_map.save_path
    )

    # Get the download struct from database (with media_item preloaded)
    download = Downloads.get_download!(download_map.id, preload: [:media_item])

    # Mark download as completed in database (prevents reprocessing on next monitor run)
    {:ok, download} = Downloads.mark_download_completed(download)

    # Track completion event
    Events.download_completed(download, media_item: download.media_item)

    if download.match_status == "unmatched" do
      # Unmatched downloads have no destination library_path and no media_item
      # to associate files with, so MediaImport can't do anything with them.
      # Leave the row in place: the user may still match it via the Issues tab
      # while the torrent is in the client. Once the torrent leaves the client,
      # handle_unmatched_orphan/1 will delete the row.
      Logger.info("Completed download is unmatched — skipping MediaImport enqueue",
        download_id: download.id
      )

      :ok
    else
      # Enqueue import job - it will delete the download record after successful import
      case enqueue_import_job(download, download_map) do
        {:ok, _job} ->
          Logger.info("Import job enqueued for completed download",
            download_id: download.id
          )

          :ok

        {:error, reason} ->
          Logger.error("Failed to enqueue import job",
            download_id: download.id,
            reason: inspect(reason)
          )

          :ok
      end
    end
  end

  # Self-heal: an unmatched download whose torrent is no longer in any client
  # is unrecoverable — nothing in the system can pair it with a media_item.
  # Delete the row so MediaImport stops retrying and the queue dedup stops
  # treating it as "active".
  defp handle_unmatched_orphan(download_map) do
    Logger.info(
      "Self-healing unmatched download — torrent gone from client, no recovery path",
      download_id: download_map.id,
      title: download_map.title,
      client: download_map.download_client
    )

    download = Downloads.get_download!(download_map.id)

    case Downloads.delete_download(download) do
      {:ok, _deleted} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to delete unmatched orphan",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  defp handle_failure(download_map) do
    # `error_message` is nil by construction here — the caller's filter only
    # selects failures we haven't handled yet. The `||` is belt-and-braces
    # for any future caller.
    error_msg =
      download_map.error_message ||
        FailureCategory.message(
          download_map.download_client,
          download_map.client_failure_category,
          download_map.client_error_detail
        )

    Logger.info("Handling failed download",
      download_id: download_map.id,
      title: download_map.title,
      failure_category: download_map.client_failure_category,
      failure_detail: download_map.client_error_detail,
      error: error_msg
    )

    # Get the download struct from database (with media_item preloaded)
    download = Downloads.get_download!(download_map.id, preload: [:media_item])

    # Track failure event before deletion. This metadata is what the activity
    # feed and the media-item history render, so the composed message is the
    # operator's only lasting record — the Download row is deleted below.
    Events.download_failed(download, error_msg, media_item: download.media_item)

    # Blacklist the release so the next search excludes it (issue #123).
    # The reason is the provider's own classification when we have one
    # (issue #237), falling back to the pre-existing generic slug.
    # This MUST NOT block failure handling — wrap in try/rescue and log.
    record_blacklist_entry(download, FailureCategory.slug(download_map.client_failure_category))

    # Delete the download record - downloads table is ephemeral
    case Downloads.delete_download(download) do
      {:ok, _deleted} ->
        Logger.info("Download removed from queue (failed)",
          download_id: download_map.id,
          error: error_msg
        )

        :ok

      {:error, changeset} ->
        Logger.error("Failed to delete failed download",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  # --- Release blacklist (#123) ------------------------------------------

  # Inserts a `release_blacklist` row keyed by the download's
  # (indexer, guid) so future searches in `TvShowSearch` / `MovieSearch`
  # filter the result out. Best-effort: rescue all errors so a failing
  # blacklist write never blocks the rest of failure handling.
  defp record_blacklist_entry(download, failure_reason) do
    case extract_blacklist_key(download) do
      {:ok, indexer, guid} ->
        try do
          case Blacklists.add(indexer, guid, download.title || "", failure_reason) do
            {:ok, _row} ->
              Logger.info("Release blacklisted after failure",
                download_id: download.id,
                indexer: indexer,
                guid: guid,
                failure_reason: failure_reason
              )

              :ok

            {:error, reason} ->
              Logger.warning("Failed to blacklist release",
                download_id: download.id,
                indexer: indexer,
                guid: guid,
                reason: inspect(reason)
              )

              :ok
          end
        rescue
          error ->
            Logger.warning("Exception while blacklisting release — continuing",
              download_id: download.id,
              error: inspect(error)
            )

            :ok
        end

      {:error, reason} ->
        Logger.debug("Skipping blacklist write — no usable key",
          download_id: download.id,
          reason: reason
        )

        :ok
    end
  end

  # Returns `{:ok, indexer, guid}` when both are present on the download.
  # The `indexer` and `guid` should have been plumbed in at download
  # creation time (see `Mydia.Downloads.Queue.create_download_record/4`).
  defp extract_blacklist_key(download) do
    indexer = download.indexer || get_in(download.metadata || %{}, ["indexer"])
    guid = get_in(download.metadata || %{}, ["guid"])

    cond do
      is_nil(indexer) or indexer == "" -> {:error, :no_indexer}
      is_nil(guid) or guid == "" -> {:error, :no_guid}
      true -> {:ok, indexer, guid}
    end
  end

  # Persists the "Grab timed out" failure on an abandoned grab (see the
  # `stale_grabs` comment in perform/1). `list_stale_grabs/1` returns real
  # `%Download{}` structs (not the enriched/derived-status list), so no
  # re-fetch is needed before updating. Uses `Downloads.update_download/2`
  # (not `mark_download_failed/2`) because it broadcasts `{:download_updated, id}`.
  defp handle_stale_grab(download) do
    Logger.warning("Grab timed out — persisting failure to release occupancy",
      download_id: download.id,
      title: download.title
    )

    case Downloads.update_download(download, %{error_message: "Grab timed out"}) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to persist stale grab timeout",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  # Persist an adoption discovered by `Mydia.Downloads.ClientAdoption`.
  #
  # Clearing the orphan error state is what makes re-adding a client a real
  # fix: delete a client, its downloads park in the Issues tab, re-add it (or
  # a client holding the same torrents) and they come back to life on the next
  # poll with no operator action. Renames heal by the same path.
  defp adopt_download(download_map) do
    Logger.info("Adopting download onto reconfigured client",
      download_id: download_map.id,
      previous_client: download_map.download_client,
      adopted_client: download_map.adoptable_client
    )

    download = Downloads.get_download!(download_map.id)

    attrs =
      %{download_client: download_map.adoptable_client}
      |> maybe_clear_orphan_state(download)

    case Downloads.update_download(download, attrs) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to adopt download onto new client",
          download_id: download_map.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  # Only clear failure state this feature created. A download carrying an
  # unrelated import failure keeps it: adoption fixes which client owns the
  # torrent, it does not vindicate a broken import.
  defp maybe_clear_orphan_state(attrs, %{import_failure_reason: "no_client"}) do
    clear_orphan_attrs(attrs)
  end

  # A row written by the release that predates the `no_client` tag: it carries
  # the old "Removed from download client" copy with no `import_failure_reason`
  # at all. Without this clause such a row is adopted (the client re-points)
  # but the stale message never clears, so it displays a permanent failure
  # forever while downloading fine, and stays outside `Download.occupying/1`.
  # A genuine import failure always sets `import_failure_reason`, so this
  # can't misfire on one.
  defp maybe_clear_orphan_state(attrs, %{import_failure_reason: nil, error_message: error_message})
       when is_binary(error_message) do
    if String.starts_with?(error_message, "Removed from download client") do
      clear_orphan_attrs(attrs)
    else
      attrs
    end
  end

  defp maybe_clear_orphan_state(attrs, _download), do: attrs

  defp clear_orphan_attrs(attrs) do
    Map.merge(attrs, %{
      error_message: nil,
      import_failure_reason: nil,
      import_last_error: nil,
      import_failed_at: nil,
      import_next_retry_at: nil
    })
  end

  defp handle_missing(download_map) do
    Logger.warning("Download missing from client - preserving for user investigation",
      download_id: download_map.id,
      title: download_map.title,
      client: download_map.download_client,
      client_config_state: download_map.client_config_state
    )

    # Get the download struct from database (with media_item preloaded)
    download = Downloads.get_download!(download_map.id, preload: [:media_item])

    error_msg = missing_error_message(download_map)

    # `Download` has no `:status` field — status is derived at read time from the
    # client poll (see `Downloads.list_downloads_with_status/1`). Persisting
    # `error_message` is what moves the row into the Issues tab, and what drops
    # it out of `Download.occupying/1` so the target is released.
    #
    # For an orphan we also persist the grouping tag the Issues tab bulk-clear
    # keys on. It is deliberately the same tag `MediaImport` emits for
    # `:no_client`, so a still-downloading orphan and one that died in import
    # group together.
    attrs =
      case download_map.client_config_state do
        state when state in [:removed, :disabled] ->
          %{error_message: error_msg, import_failure_reason: "no_client"}

        _present_or_unassigned ->
          %{error_message: error_msg}
      end

    case Downloads.update_download(download, attrs) do
      {:ok, _updated} ->
        Logger.info("Download marked as missing (preserved for Issues tab)",
          download_id: download_map.id,
          client: download_map.download_client
        )

        # Track event for user visibility
        Events.download_failed(download, error_msg, media_item: download.media_item)
        :ok

      {:error, changeset} ->
        Logger.error("Failed to mark download as missing",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  @doc false
  # Public, with a function head, only so the copy-selection branches can be
  # tested without standing up a reachable client behind a Bypass stub. The
  # function is pure: it maps a config state to a string and touches nothing
  # else. Not part of the module's intended API.
  def missing_error_message(download_map)

  # The client is gone: deleted from the UI, dropped from env vars, or renamed
  # (matching is by name, so a rename is indistinguishable from a delete).
  # Naming the removal is the point — the operator otherwise goes and inspects
  # a download client that is perfectly healthy.
  def missing_error_message(%{client_config_state: :removed} = download_map) do
    "Download client '#{download_map.download_client}' is no longer configured in Mydia. " <>
      "The download may still be running in the client itself. " <>
      "Re-add the client to resume tracking, or clear this download."
  end

  # The client still exists but is switched off, so Mydia never polls it.
  def missing_error_message(%{client_config_state: :disabled} = download_map) do
    "Download client '#{download_map.download_client}' is disabled in Mydia, so its " <>
      "downloads are no longer tracked. Re-enable the client to resume tracking, " <>
      "or clear this download."
  end

  # The original case: a configured, reachable client reported that it does not
  # have this torrent.
  def missing_error_message(download_map) do
    "Removed from download client '#{download_map.download_client}' before import completed. " <>
      "The download may have been manually deleted, or the client may have encountered an error."
  end

  defp handle_stuck(download) do
    # Calculate how long the download has been stuck
    hours_stuck =
      DateTime.diff(DateTime.utc_now(), download.completed_at, :hour)

    Logger.warning("Download stuck - completed but never imported",
      download_id: download.id,
      title: download.title,
      completed_at: download.completed_at,
      hours_stuck: hours_stuck
    )

    error_msg =
      "Import stalled - download completed #{hours_stuck} hour(s) ago but import never ran. " <>
        "This may indicate the import job failed silently or was never scheduled. " <>
        "A new import will be attempted automatically."

    # Flag as failed so it appears in Issues tab
    case Downloads.update_download(download, %{
           import_failed_at: DateTime.utc_now(),
           import_last_error: error_msg
         }) do
      {:ok, updated} ->
        Logger.info("Stuck download flagged for investigation",
          download_id: download.id
        )

        # Track event for user visibility
        Events.download_failed(download, error_msg, media_item: download.media_item)

        # Enqueue a new import job to retry
        enqueue_import_job(updated)

      {:error, changeset} ->
        Logger.error("Failed to flag stuck download",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )
    end
  end

  # --- Stall detection ----------------------------------------------------

  # Build a `%{client_name => grace_minutes}` map once per poll. Both DB-backed
  # and runtime-config clients flow through `Settings.list_download_client_configs/0`,
  # so a single source is enough.
  defp build_grace_map do
    Settings.list_download_client_configs()
    |> Enum.into(%{}, fn config ->
      {config.name, config.incomplete_grace_minutes || @default_grace_minutes}
    end)
  end

  defp grace_minutes_for(client_name, grace_map) do
    Map.get(grace_map, client_name, @default_grace_minutes)
  end

  # Iterate active downloads and apply the StallDetector decision. Returns the
  # number of downloads newly entering a stalled state (soft-stall or escalation)
  # this poll. Every observed download has `last_observed_at` refreshed to `now`
  # (throttled — see `apply_progress_decision/3` for `:no_change`) so the gap
  # reset doesn't fire on the next poll.
  defp check_progress(active_downloads, grace_map, now) do
    Enum.reduce(active_downloads, 0, fn download, stalled_acc ->
      grace = grace_minutes_for(download.download_client, grace_map)
      escalation = grace * @stall_escalation_multiplier

      decision =
        StallDetector.evaluate(
          download.last_progress_at,
          download.last_known_bytes,
          download.last_observed_at,
          download.stalled_since,
          download.downloaded || 0,
          %StallDetector.Thresholds{
            grace_minutes: grace,
            escalation_minutes: escalation,
            gap_threshold_seconds: @observation_gap_seconds
          },
          now
        )

      increment =
        try do
          apply_progress_decision(download, decision, now)
        rescue
          # The row was deleted between the poll's status snapshot and this
          # write (e.g. a concurrent import that deletes the download, or a
          # manual delete). Skip it — the rest of the poll must still run.
          Ecto.NoResultsError ->
            Logger.debug("Download disappeared mid-poll; skipping stall update",
              download_id: download.id
            )

            0
        end

      increment + stalled_acc
    end)
  end

  # No stall transition, but record that we observed this download so the gap
  # reset doesn't fire on the next poll, and a held soft-stall keeps maturing
  # toward escalation without self-resetting. Throttled: refreshing on every
  # poll would issue a write + PubSub broadcast (which re-polls the client for
  # every open Downloads view) for an otherwise-idle download. A refresh only
  # has to keep `now - last_observed_at` under @observation_gap_seconds, so
  # writing once it is half-stale is sufficient and far cheaper.
  defp apply_progress_decision(download, :no_change, now) do
    if observation_stale?(download.last_observed_at, now) do
      update_progress(download, %{last_observed_at: now})
    end

    0
  end

  defp apply_progress_decision(download, {:initialize, now}, _now) do
    update_progress(download, %{
      last_progress_at: now,
      last_known_bytes: download.downloaded || 0,
      last_observed_at: now,
      stalled_since: nil
    })

    0
  end

  # Observation gap — fresh baseline, clears any in-flight soft-stall. Bytes were
  # unchanged so `last_known_bytes` is left as-is.
  defp apply_progress_decision(download, {:reset, now}, _now) do
    apply_recovery(download, %{
      last_progress_at: now,
      last_observed_at: now,
      stalled_since: nil
    })

    0
  end

  defp apply_progress_decision(download, {:progress, new_bytes, now}, _now) do
    apply_recovery(download, %{
      last_progress_at: now,
      last_known_bytes: new_bytes,
      last_observed_at: now,
      stalled_since: nil
    })

    0
  end

  # A recoverable soft-stall: keep `import_failed_at` nil so the episode stays
  # occupied, record `stalled_since`, and emit a warning event.
  defp apply_progress_decision(download, {:soft_stall, message, now}, _now) do
    Logger.warning("Download soft-stalled — no progress within grace window",
      download_id: download.id,
      download_client: download.download_client,
      last_progress_at: download.last_progress_at,
      last_known_bytes: download.last_known_bytes,
      downloaded: download.downloaded,
      message: message
    )

    db_download = Downloads.get_download!(download.id, preload: [:media_item])

    case Downloads.update_download(db_download, %{
           stalled_since: now,
           last_observed_at: now
         }) do
      {:ok, updated} ->
        Events.download_stalled(updated, message, media_item: updated.media_item)
        1

      {:error, changeset} ->
        Logger.error("Failed to flag soft-stalled download",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        0
    end
  end

  # Escalation — a soft-stall that outlasted the longer threshold becomes a
  # terminal failure, releasing the episode for re-search (today's terminal
  # behaviour, now reached only after escalation).
  #
  # IMPORTANT: do NOT cast `:status` here — `Download.changeset/2` silently
  # drops it (known bug, tracked separately). Use `import_failed_at` +
  # `import_last_error` as the terminal signal.
  defp apply_progress_decision(download, {:escalate, error_message, now}, _now) do
    Logger.warning("Download stall escalated to terminal failure",
      download_id: download.id,
      download_client: download.download_client,
      stalled_since: download.stalled_since,
      error: error_message
    )

    db_download = Downloads.get_download!(download.id, preload: [:media_item])

    case Downloads.update_download(db_download, %{
           import_failed_at: now,
           import_last_error: error_message,
           last_observed_at: now
         }) do
      {:ok, updated} ->
        Events.download_failed(updated, error_message, media_item: updated.media_item)
        1

      {:error, changeset} ->
        Logger.error("Failed to escalate stalled download",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        0
    end
  end

  # Persist a progress/reset decision that clears any in-flight soft-stall,
  # emitting a recovery event only when a soft-stall was actually cleared.
  defp apply_recovery(download, attrs) do
    if is_nil(download.stalled_since) do
      update_progress(download, attrs)
    else
      db_download = Downloads.get_download!(download.id, preload: [:media_item])

      case Downloads.update_download(db_download, attrs) do
        {:ok, updated} ->
          Events.download_unstalled(updated, media_item: updated.media_item)
          :ok

        {:error, changeset} ->
          Logger.warning("Failed to clear soft-stall on download",
            download_id: download.id,
            errors: inspect(changeset.errors)
          )

          :ok
      end
    end
  end

  # Whether `last_observed_at` is stale enough to be worth refreshing on an
  # otherwise-idle poll. Half the gap threshold leaves ample margin: even with
  # the slowest (cron) poll spacing, the next observation stays well under
  # @observation_gap_seconds, so the gap reset never false-fires.
  defp observation_stale?(nil, _now), do: true

  defp observation_stale?(last_observed_at, now) do
    DateTime.diff(now, last_observed_at, :second) > div(@observation_gap_seconds, 2)
  end

  defp update_progress(download, attrs) do
    db_download = Downloads.get_download!(download.id)

    case Downloads.update_download(db_download, attrs) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to update download progress tracking",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  # Resolve the current time from job args (test injection) or fall back to
  # `DateTime.utc_now/0`. Accepts ISO8601 strings or `DateTime` structs.
  defp resolve_now(args) when is_map(args) do
    case Map.get(args, "now") do
      nil ->
        DateTime.utc_now()

      %DateTime{} = dt ->
        dt

      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _offset} ->
            dt

          {:error, _} ->
            Logger.warning("Invalid 'now' arg passed to DownloadMonitor, falling back to utc_now",
              value: iso
            )

            DateTime.utc_now()
        end
    end
  end

  defp resolve_now(_), do: DateTime.utc_now()

  # --- Import job helpers -------------------------------------------------

  # Enqueue import job with save_path from client status (normal completion flow)
  defp enqueue_import_job(download, download_map) do
    %{
      "download_id" => download.id,
      "save_path" => download_map.save_path,
      "cleanup_client" => true,
      "use_hardlinks" => true,
      "move_files" => false
    }
    |> Mydia.Jobs.MediaImport.new()
    |> Oban.insert()
  end

  # Enqueue import job for stuck downloads (save_path will be fetched by MediaImport)
  defp enqueue_import_job(download) do
    changeset =
      %{
        "download_id" => download.id,
        "cleanup_client" => true,
        "use_hardlinks" => true,
        "move_files" => false
      }
      |> Mydia.Jobs.MediaImport.new()

    # Use Oban.insert if available, otherwise fall back to Repo.insert for testing
    result =
      try do
        Oban.insert(changeset)
      rescue
        RuntimeError ->
          # In testing mode without running Oban, insert directly via Repo
          Mydia.Repo.insert(changeset)
      end

    case result do
      {:ok, job} ->
        Logger.info("Retry import job enqueued for stuck download",
          download_id: download.id,
          job_id: job.id
        )

        {:ok, job}

      {:error, reason} = error ->
        Logger.error("Failed to enqueue retry import job",
          download_id: download.id,
          reason: inspect(reason)
        )

        error
    end
  end
end
