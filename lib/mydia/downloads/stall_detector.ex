defmodule Mydia.Downloads.StallDetector do
  @moduledoc """
  Pure progress-tracking logic for the `DownloadMonitor` stall-detection circuit
  breaker (see issue #126).

  The stall clock only accrues over *observed, actively-downloading* time. On
  each poll cycle the monitor passes in the download's persisted progress state
  plus the bytes-downloaded reported by the client, and this module returns a
  decision the monitor persists:

    * **Observation gap → reset.** If too much wall-clock has elapsed since the
      last observation (`last_observed_at`), the download was *not* observed for
      a stretch — a client outage, a Mydia restart, or a paused/queued torrent.
      We can't attribute that gap to a stall, so we reset the baseline
      (`last_progress_at = now`) and clear any in-flight soft-stall. This is the
      single mechanism that makes stall-detection resilient to outages.
    * **Progress → advance.** If the client reports a different byte count
      (more, or a regression from a client restart), the download made progress;
      advance `last_progress_at`/`last_known_bytes` and clear any soft-stall.
    * **Soft-stall.** If bytes are unchanged, the download was observed
      continuously (no gap), and `(now - last_progress_at)` exceeded the
      per-client grace window, we record a *recoverable* soft-stall
      (`stalled_since = now`). A soft-stall keeps occupying its episode — it is
      NOT a terminal `import_failed_at` failure — and auto-clears on resumed
      progress or a gap reset.
    * **Escalate.** A download that stays continuously soft-stalled past a
      separate, longer escalation threshold is one we give up on: the monitor
      rejects the release outright (blocklists it briefly, removes the torrent
      from the client, deletes the row, and queues a replacement search).
    * **Initialize.** First time we see a download (`last_progress_at` nil) we
      set the baseline and never flag stalled on first sight.

  This module is deliberately decoupled from Ecto / Oban so it can be unit
  tested with pure data. Persistence, escalation writes, and event emission stay
  in `Mydia.Jobs.DownloadMonitor`.
  """

  alias Mydia.Downloads.StallDetector.Thresholds

  # A soft-stall escalates to a give-up after grace × this. A dedicated
  # per-client knob is deliberately deferred (see the stall give-up spec).
  @escalation_multiplier 3

  @type decision ::
          :no_change
          | {:initialize, now :: DateTime.t()}
          | {:reset, now :: DateTime.t()}
          | {:progress, new_bytes :: non_neg_integer(), now :: DateTime.t()}
          | {:soft_stall, message :: String.t(), now :: DateTime.t()}
          | {:escalate, message :: String.t(), now :: DateTime.t()}

  @doc """
  Decide what to do with a download whose progress we just observed.

  ## Parameters

    * `last_progress_at` — timestamp of the last bytes-downloaded increment, or
      `nil` for a download we have not tracked yet.
    * `last_known_bytes` — bytes-downloaded count at `last_progress_at`. May be
      `nil` if the row predates the column; treated as `0`.
    * `last_observed_at` — timestamp of the last poll in which this download was
      observed actively downloading, or `nil` for a row that predates the column
      (treated as a gap → reset).
    * `stalled_since` — timestamp the current soft-stall began, or `nil` if not
      soft-stalled.
    * `observed_bytes` — bytes-downloaded reported by the client right now.
    * `thresholds` — a `Thresholds` struct carrying the `grace_minutes`,
      `escalation_minutes`, and `gap_threshold_seconds` tuning knobs.
    * `now` — the current `DateTime` (injected for test determinism).

  ## Returned decisions

    * `:no_change` — no stall-state transition to persist. The monitor still
      records that it observed the download (a throttled `last_observed_at = now`
      refresh — see `DownloadMonitor`), which keeps the gap reset from firing on
      the next poll. Includes holding an immature soft-stall.
    * `{:initialize, now}` — first observation. Set `last_progress_at = now` and
      `last_known_bytes = observed_bytes`.
    * `{:reset, now}` — observation gap. Set `last_progress_at = now`, clear
      `stalled_since`. The byte baseline is left as-is (bytes were unchanged).
    * `{:progress, observed_bytes, now}` — bytes changed. Set
      `last_progress_at = now`, `last_known_bytes = observed_bytes`, clear
      `stalled_since`.
    * `{:soft_stall, message, now}` — bytes unchanged past the grace window. Set
      `stalled_since = now`; leave `import_failed_at` nil (episode retained).
    * `{:escalate, message, now}` — soft-stalled past the escalation threshold.
      The monitor rejects the release; `message` is recorded on the emitted
      `download.failed` event.

  Boundary semantics: a download whose baseline is EXACTLY `grace_minutes` old is
  *not yet* soft-stalled, and one stalled EXACTLY `escalation_minutes` is *not
  yet* escalated. Both checks use strict `>`.
  """
  @spec evaluate(
          DateTime.t() | nil,
          non_neg_integer() | nil,
          DateTime.t() | nil,
          DateTime.t() | nil,
          non_neg_integer(),
          Thresholds.t(),
          DateTime.t()
        ) :: decision()
  def evaluate(
        last_progress_at,
        last_known_bytes,
        last_observed_at,
        stalled_since,
        observed_bytes,
        %Thresholds{
          grace_minutes: grace_minutes,
          escalation_minutes: escalation_minutes,
          gap_threshold_seconds: gap_threshold_seconds
        },
        now
      )
      when is_integer(observed_bytes) and observed_bytes >= 0 and
             is_integer(grace_minutes) and grace_minutes > 0 and
             is_integer(escalation_minutes) and escalation_minutes > 0 and
             is_integer(gap_threshold_seconds) and gap_threshold_seconds > 0 do
    known = last_known_bytes || 0

    cond do
      is_nil(last_progress_at) ->
        {:initialize, now}

      # Observation gap — the download was not observed for a stretch (outage,
      # restart, paused/queued). Reset the baseline rather than attribute the
      # gap to a stall, and clear any in-flight soft-stall.
      is_nil(last_observed_at) or
          DateTime.diff(now, last_observed_at, :second) > gap_threshold_seconds ->
        {:reset, now}

      # Bytes changed — progress (or a regression from a client restart). Either
      # way reset the clock so we never false-trip the stall window, and
      # auto-clear an in-flight soft-stall.
      observed_bytes != known ->
        {:progress, observed_bytes, now}

      # Currently soft-stalled and observed continuously: either escalate (past
      # the longer threshold) or hold the soft-stall.
      not is_nil(stalled_since) ->
        if DateTime.diff(now, stalled_since, :second) > escalation_minutes * 60 do
          {:escalate, escalation_message(grace_minutes, escalation_minutes), now}
        else
          :no_change
        end

      # Not yet stalled: enter a soft-stall once the grace window has elapsed.
      DateTime.diff(now, last_progress_at, :second) > grace_minutes * 60 ->
        {:soft_stall, stalled_message(grace_minutes), now}

      true ->
        :no_change
    end
  end

  @doc """
  Build the standardised soft-stall error message. The Downloads LiveView matches
  on the leading `"stalled"` substring to surface the badge.
  """
  @spec stalled_message(pos_integer()) :: String.t()
  def stalled_message(grace_minutes) when is_integer(grace_minutes) and grace_minutes > 0 do
    "stalled after #{grace_minutes}m without progress"
  end

  @doc """
  How long a soft-stall may persist before we give up, derived from the
  per-client grace window.

  Single-sourced here rather than in `DownloadMonitor` so the Downloads
  LiveView can show the operator the same deadline the monitor will act on,
  with no chance of the two drifting apart.
  """
  @spec escalation_minutes(pos_integer()) :: pos_integer()
  def escalation_minutes(grace_minutes)
      when is_integer(grace_minutes) and grace_minutes > 0 do
    grace_minutes * @escalation_multiplier
  end

  @doc """
  Build the give-up message recorded on the `download.failed` event.

  Reports the *total* time without progress (grace + escalation). The previous
  message reported only the escalation window, understating the stall by the
  whole grace window, and asserted "escalated to failure" while leaving the
  torrent running. The consequence now lives on the event's `failure_category`
  and in what actually happens to the download.
  """
  @spec escalation_message(pos_integer(), pos_integer()) :: String.t()
  def escalation_message(grace_minutes, escalation_minutes)
      when is_integer(grace_minutes) and grace_minutes > 0 and
             is_integer(escalation_minutes) and escalation_minutes > 0 do
    "no progress for #{format_window(grace_minutes + escalation_minutes)}"
  end

  defp format_window(minutes) when minutes < 60, do: "#{minutes}m"

  defp format_window(minutes) do
    case {div(minutes, 60), rem(minutes, 60)} do
      {hours, 0} -> "#{hours}h"
      {hours, rest} -> "#{hours}h #{rest}m"
    end
  end
end
