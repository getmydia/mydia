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
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.ClientAdoption
  alias Mydia.Downloads.Client.FailureCategory
  alias Mydia.Downloads.ImportCandidates
  alias Mydia.Downloads.Queue
  alias Mydia.Downloads.StallDetector
  alias Mydia.Downloads.ExternalTorrents
  alias Mydia.Downloads.UntrackedMatcher
  alias Mydia.Events
  alias Mydia.Settings

  # How long a give-up blocklists the release. Deliberately far shorter than
  # the 30-day default: a torrent with no seeds today may have seeds tomorrow,
  # so a stall earns a cooldown, not the near-permanent ban a corrupt release
  # gets.
  @stall_blacklist_ttl_days 1

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

    # Backfill the grouping tag onto orphans the previously released code
    # already marked. Those rows carry an `error_message`, and the `missing`
    # filter below requires a nil one, so they can never re-enter
    # `handle_missing/1` to be tagged: without this the operator upgrading with
    # a backlog of falsely blamed orphans, which is exactly who this feature is
    # for, would see no banner at all. Runs after the adoption pass and skips
    # anything it just healed.
    downloads
    |> Enum.filter(&legacy_orphan?/1)
    |> Enum.each(&tag_legacy_orphan/1)

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
        d.status == "missing" and is_nil(d.db_completed_at) and is_nil(d.error_message)
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

    # A torrent's file list is known as soon as the client has its metadata —
    # immediately for a direct .torrent add, within seconds for a magnet —
    # long before the payload itself finishes downloading. Reject on sight
    # rather than waiting for completion: this is what stops a malware
    # torrent (a single disguised .exe with no video file at all) from
    # pulling its full multi-hundred-MB-to-multi-GB payload just to be
    # thrown away by the post-completion importer.
    {bad_content, content_checked_ids} = evaluate_content(active_for_stall_check)
    Downloads.mark_content_checked(content_checked_ids)

    active_for_stall_check = active_for_stall_check -- bad_content

    Logger.info(
      "Found #{length(completed)} newly completed, #{length(failed)} newly failed, #{length(missing)} missing downloads, #{length(stale_grabs)} stale grabs, #{length(bad_content)} bad-content downloads, #{length(active_for_stall_check)} active for stall check"
    )

    # Handle completions
    Enum.each(completed, &handle_completion/1)

    # Handle failures
    Enum.each(failed, &handle_failure/1)

    # Handle missing downloads
    Enum.each(missing, &handle_missing/1)

    # Reject torrents whose file list is already known to contain nothing
    # importable, before they finish downloading.
    Enum.each(bad_content, &reject_bad_content/1)

    # Self-heal abandoned grabs (persist the timeout so occupancy is released)
    Enum.each(stale_grabs, &handle_stale_grab/1)

    # Track progress / flag stalled downloads. Grace minutes are read from each
    # download's configured client (DB or runtime config) — cached per poll.
    grace_map = Settings.download_client_grace_map()
    stalled_count = check_progress(active_for_stall_check, grace_map, now)

    # Find and match untracked torrents (manually added to clients)
    untracked_downloads = UntrackedMatcher.find_and_match_untracked()
    Logger.info("Matched #{length(untracked_downloads)} untracked torrent(s) to library items")

    # Refresh the derived view of torrents Mydia does not manage. Runs after
    # adoption so anything just adopted is already tracked and drops out of the
    # scan on this pass rather than the next one.
    external_scan = ExternalTorrents.refresh()

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
      stale_grabs_cleaned: length(stale_grabs),
      stalled_count: stalled_count,
      stuck_count: length(stuck),
      untracked_matched: length(untracked_downloads),
      external_needs_matching: length(external_scan.needs_matching),
      external_other: length(external_scan.external)
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

    # Bound once and used for both the event and the blacklist row below, so
    # the activity feed and the admin blacklist page can never disagree about
    # why this release failed (issue #237).
    failure_slug = FailureCategory.slug(download_map.client_failure_category)

    # Track failure event before deletion. This metadata is what the activity
    # feed and the media-item history render, so the composed message is the
    # operator's only lasting record. The Download row is deleted below.
    Events.download_failed(download, error_msg,
      media_item: download.media_item,
      failure_category: failure_slug,
      failure_detail: download_map.client_error_detail
    )

    # Blacklist the release so the next search excludes it (issue #123).
    # The reason is the provider's own classification when we have one
    # (issue #237), falling back to the pre-existing generic slug.
    # This MUST NOT block failure handling, so wrap in try/rescue and log.
    record_blacklist_entry(download, failure_slug)

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

  # --- Pre-completion content check --------------------------------------

  # Decides which active downloads hold nothing importable, and which ones we
  # managed to evaluate at all.
  #
  # This deliberately does NOT read `DownloadStatus.files`. That field is an
  # import-*scoping* path and qBittorrent and rtorrent both report a single
  # entry that is the torrent's root DIRECTORY, whose extension
  # (`.x264-YTS`, or none at all) is never a video extension. Judging content
  # from it rejected every multi-file qBittorrent torrent mid-download,
  # blacklisted the release, deleted the data and grabbed a replacement that
  # met the same fate. `Client.list_files/3` is the enumeration contract:
  # adapters that cannot enumerate report `:unsupported` and are skipped.
  #
  # `{:error, _}` and `{:ok, []}` both mean "we do not know". An empty list
  # from a torrent client means metadata has not resolved yet, never that the
  # torrent is empty, so neither is stamped and both are retried next poll.
  defp evaluate_content(candidates) do
    Enum.reduce(candidates, {[], []}, fn download_map, {bad, checked} ->
      if download_map.content_checked_at do
        {bad, checked}
      else
        case enumerate_files(download_map) do
          {:ok, [_ | _] = files} ->
            if Enum.any?(files, &importable_path?/1) do
              {bad, [download_map.id | checked]}
            else
              {[download_map | bad], [download_map.id | checked]}
            end

          _unknown ->
            {bad, checked}
        end
      end
    end)
  end

  defp enumerate_files(download_map) do
    with {:ok, adapter, config} <- Queue.resolve_adapter(download_map.download_client) do
      Client.list_files(adapter, config, download_map.download_client_id)
    end
  end

  # `downloads.media_item_id` only ever points at a `movie` or `tv_show` media
  # item (the only two `MediaItem.valid_types/0`), so every download reaching
  # this check wants a video file regardless of which of the two it is:
  # `ImportCandidates.importable?/2` treats `:movies`/`:series`/`:mixed`
  # identically. Passing `:series` unconditionally is exact, not a guess.
  defp importable_path?(path) do
    ImportCandidates.importable?(%{name: Path.basename(path)}, :series)
  end

  # Rejects a still-downloading torrent whose already-known file list
  # contains not a single file with a video extension — same treatment as an
  # operator manually rejecting a release from the Issues tab (blacklist the
  # `(indexer, guid)`, remove the torrent and its data from the client,
  # delete the row, queue a replacement search), just triggered automatically
  # and before the payload finishes downloading instead of after.
  # Capped so a large season pack (hundreds of files) doesn't blow up this
  # warning into an outsized log line.
  @bad_content_log_sample 10

  defp reject_bad_content(download_map) do
    download = Downloads.get_download!(download_map.id, preload: [:media_item])

    if auto_reject_exhausted?(download.media_item_id) do
      suppress_auto_reject(download, download_map)
    else
      do_reject_bad_content(download, download_map)
    end
  rescue
    Ecto.NoResultsError -> :ok
  end

  # A media item with no id (an unbound download) has no counter to consult,
  # so it is never capped.
  defp auto_reject_exhausted?(nil), do: false

  defp auto_reject_exhausted?(media_item_id) do
    case Mydia.Search.get_backoff_info("auto_reject", media_item_id) do
      %{failure_count: count} -> count >= auto_reject_limit()
      _ -> false
    end
  end

  # The torrent is left completely untouched. Writing `import_failure_reason`
  # here would be the obvious way to surface it, but the Issues filter
  # (Mydia.Downloads.History, the `:failed` branch) needs `import_failed_at`
  # or a failed/missing status, and setting either would present a healthy,
  # still-progressing download as terminally failed. When the cap trips the
  # likely truth is that our detector is wrong, so the right outcome is that
  # this download finishes and imports.
  defp suppress_auto_reject(download, download_map) do
    Logger.warning(
      "Auto-reject limit reached, leaving download alone",
      download_id: download_map.id,
      title: download_map.title,
      media_item_id: download.media_item_id,
      limit: auto_reject_limit()
    )

    Events.download_auto_reject_suppressed(download, media_item: download.media_item)
    :ok
  end

  defp do_reject_bad_content(download, download_map) do
    Logger.warning(
      "Rejecting download before completion — no importable files in torrent",
      download_id: download_map.id,
      title: download_map.title,
      file_count: length(download_map.files || []),
      files_sample:
        (download_map.files || [])
        |> Enum.take(@bad_content_log_sample)
        |> Enum.map(&Path.basename/1)
    )

    case Queue.reject_release(download,
           actor_type: :system,
           actor_id: "download_monitor",
           failure_reason: "no_importable_files"
         ) do
      {:ok, :rejected} ->
        # Counted only once the rejection actually happened. Counting it up
        # front would let a release that can never be rejected (no indexer or
        # guid, so `Blacklists.extract_key/1` fails) burn through the cap and
        # suppress future *real* auto-rejections for this item, having never
        # rejected anything.
        if download.media_item_id do
          Mydia.Search.record_failure(
            "auto_reject",
            download.media_item_id,
            "no_importable_files"
          )
        end

        :ok

      {:error, reason} ->
        Logger.warning("Could not auto-reject bad-content download",
          download_id: download_map.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  # See UpgradeSweep.enabled?/0 for why this reads through the layered runtime
  # config rather than a flat Application.get_env key: nothing explodes the
  # resolved Config.Schema struct back out to flat top-level keys, so a flat
  # read would silently ignore both the env var and the settings UI.
  defp auto_reject_limit do
    case Mydia.Config.get() do
      %{downloads: %{auto_reject_limit: limit}} when is_integer(limit) and limit > 0 -> limit
      _ -> 3
    end
  end

  # --- Release blacklist (#123) ------------------------------------------

  # Inserts a `release_blacklist` row keyed by the download's
  # (indexer, guid) so future searches in `TvShowSearch` / `MovieSearch`
  # filter the result out. Best-effort: rescue all errors so a failing
  # blacklist write never blocks the rest of failure handling.
  defp record_blacklist_entry(download, failure_reason) do
    case Blacklists.extract_key(download) do
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

  # Persist an adoption proposed by the read path.
  #
  # Clearing the orphan error state is what makes re-adding a client a real
  # fix: delete a client, its downloads park in the Issues tab, re-add it (or
  # a client holding the same torrents) and they come back to life on the next
  # poll with no operator action. Renames heal by the same path.
  #
  # The proposed client can also be the row's own, which is how a client that
  # was merely disabled and then re-enabled heals (see `heal_own_client/1` in
  # `Mydia.Downloads.History`). The `download_client` write is then a no-op and
  # only the orphan state clears.
  defp adopt_download(download_map) do
    download = Downloads.get_download!(download_map.id)

    attrs =
      %{download_client: download_map.adoptable_client}
      |> maybe_clear_orphan_state(download)

    if attrs == %{download_client: download.download_client} do
      # Nothing to persist: the row already names this client and carries no
      # orphan state to clear. Writing anyway would broadcast a download update
      # on every single poll, and every open Downloads view re-polls all its
      # clients on that broadcast. Only reachable if the row changed between
      # the poll's snapshot and this write.
      :ok
    else
      Logger.info("Adopting download onto reconfigured client",
        download_id: download_map.id,
        previous_client: download.download_client,
        adopted_client: download_map.adoptable_client
      )

      persist_adoption(download, download_map, attrs)
    end
  end

  defp persist_adoption(download, download_map, attrs) do
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
  #
  # The predicate is shared with the read path that proposes the adoption in
  # the first place (see `Mydia.Downloads.ClientAdoption.orphan_state?/2`), so
  # the two can never disagree about whether a heal is available.
  defp maybe_clear_orphan_state(attrs, download) do
    if ClientAdoption.orphan_state?(download.import_failure_reason, download.error_message) do
      clear_orphan_attrs(attrs)
    else
      attrs
    end
  end

  defp clear_orphan_attrs(attrs) do
    Map.merge(attrs, %{
      error_message: nil,
      import_failure_reason: nil,
      import_last_error: nil,
      import_failed_at: nil,
      import_next_retry_at: nil
    })
  end

  # An orphan the previous release marked: the old "Removed from download
  # client" copy, no `import_failure_reason` (the tag did not exist yet), and a
  # client that is still gone or switched off today.
  defp legacy_orphan?(%{import_failure_reason: nil} = download_map) do
    download_map.client_config_state in [:removed, :disabled] and
      is_nil(download_map.adoptable_client) and
      ClientAdoption.orphan_state?(nil, download_map.error_message)
  end

  defp legacy_orphan?(_download_map), do: false

  # Tag only. The message is left exactly as it was written, and no
  # `Events.download_failed/3` is emitted: these failures already happened and
  # were already reported, so replaying them would dump a backlog of stale
  # failures into the activity feed on the first poll after an upgrade.
  defp tag_legacy_orphan(download_map) do
    Logger.info("Tagging pre-existing orphaned download for grouping",
      download_id: download_map.id,
      client: download_map.download_client,
      client_config_state: download_map.client_config_state
    )

    download = Downloads.get_download!(download_map.id)

    case Downloads.update_download(download, %{import_failure_reason: "no_client"}) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to tag pre-existing orphaned download",
          download_id: download_map.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
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

  defp grace_minutes_for(client_name, grace_map) do
    Map.get(grace_map, client_name, Settings.default_grace_minutes())
  end

  # Iterate active downloads and apply the StallDetector decision. Returns the
  # number of downloads newly entering a stalled state (soft-stall or escalation)
  # this poll. Every observed download has `last_observed_at` refreshed to `now`
  # (throttled — see `apply_progress_decision/3` for `:no_change`) so the gap
  # reset doesn't fire on the next poll.
  defp check_progress(active_downloads, grace_map, now) do
    Enum.reduce(active_downloads, 0, fn download, stalled_acc ->
      grace = grace_minutes_for(download.download_client, grace_map)
      escalation = StallDetector.escalation_minutes(grace)

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

  # A soft-stall that outlasted the escalation window is a release we give up
  # on. Reuse the same reject path bad content uses rather than inventing a
  # third terminal shape: blocklist briefly, pull the torrent from the client,
  # delete the row, queue a replacement. The old behaviour wrote two import
  # fields and left the torrent running, which read to operators as "Mydia
  # says this failed but it is still downloading".
  defp apply_progress_decision(download, {:escalate, error_message, _at}, _now) do
    db_download = Downloads.get_download!(download.id, preload: [:media_item])

    if auto_reject_exhausted?(db_download.media_item_id) do
      suppress_stall_reject(db_download, error_message)
    else
      do_reject_stalled(db_download, error_message)
    end
  end

  defp do_reject_stalled(download, error_message) do
    Logger.warning("Giving up on stalled download",
      download_id: download.id,
      download_client: download.download_client,
      stalled_since: download.stalled_since,
      error: error_message
    )

    # Emitted before the reject deletes the row: this event is the operator's
    # only lasting record, same as the client-failure path at the top of this
    # module.
    Events.download_failed(download, error_message,
      media_item: download.media_item,
      failure_category: "stalled",
      failure_detail: download.download_client
    )

    case Queue.reject_release(download,
           actor_type: :system,
           actor_id: "download_monitor",
           failure_reason: "stalled",
           ttl_days: @stall_blacklist_ttl_days,
           event: :none
         ) do
      {:ok, :rejected} ->
        if download.media_item_id do
          Mydia.Search.record_failure("auto_reject", download.media_item_id, "stalled")
        end

      {:error, reason} ->
        Logger.warning("Could not clear stalled download",
          download_id: download.id,
          reason: inspect(reason)
        )
    end

    1
  end

  # Same reasoning as suppress_auto_reject/2: when the cap trips, the likeliest
  # truth is that our detector is wrong, so the right outcome is that this
  # download finishes and imports. Touch nothing.
  defp suppress_stall_reject(download, error_message) do
    Logger.warning("Auto-reject limit reached, leaving stalled download alone",
      download_id: download.id,
      title: download.title,
      media_item_id: download.media_item_id,
      limit: auto_reject_limit(),
      error: error_message
    )

    Events.download_auto_reject_suppressed(download, media_item: download.media_item)

    1
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
