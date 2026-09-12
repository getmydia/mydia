defmodule Mydia.LibraryApi.RevisionClock do
  @moduledoc """
  The clock-derived availability catch-up.

  A show's Library API availability is derived from its episodes' `air_date`, so
  `UPCOMING` becomes `AVAILABLE` at a UTC date boundary with no row written for
  the revision triggers to observe. This module is the only thing that advances
  those markers: it names every show whose episode crossed the watermark and
  hands the ids to `Mydia.LibraryApi.RevisionFeed.mark_live/1`, which applies the
  same database-allocated, greater-revision upsert the triggers use.

  The watermark and the markers move in one transaction, so a crash cannot leave
  the watermark advanced with the markers unmarked (a lost delivery) or the
  markers advanced with the watermark stale (a repeated delivery every boot).
  Re-running the sweep for a day that was already processed is a no-op.

  On SQLite the transaction opens with `mode: :immediate` so the single writer
  lock is taken up front and the read of the watermark cannot race another
  writer. On PostgreSQL the singleton row is locked `FOR UPDATE` for the same
  reason.
  """

  import Ecto.Query

  alias Mydia.DB
  alias Mydia.LibraryApi.RevisionClockState
  alias Mydia.LibraryApi.RevisionFeed
  alias Mydia.Media.Episode
  alias Mydia.Repo

  @doc """
  Advances the watermark to `today`, marking every show whose episode air date
  crossed into or before it.

  Returns `{:ok, count}` with the number of distinct shows marked, or `0` when the
  watermark is already at or past `today`. `{:error, reason}` means the whole
  transaction rolled back, so neither the markers nor the watermark changed.

  Options:

    * `:after_mark` — a zero-arity function called after the markers are advanced
      and before the watermark is updated. Test-only failure injection.
  """
  @spec catch_up(Date.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def catch_up(today \\ Date.utc_today(), opts \\ []) do
    transaction_opts = if DB.sqlite?(), do: [mode: :immediate], else: []

    Repo.transaction(
      fn ->
        state_query = from(s in RevisionClockState, where: s.id == 1)
        state_query = if DB.postgres?(), do: lock(state_query, "FOR UPDATE"), else: state_query
        state = Repo.one!(state_query)

        if Date.compare(state.last_processed_date, today) == :lt do
          ids = crossed_show_ids(state.last_processed_date, today)
          :ok = RevisionFeed.mark_live(ids)
          after_mark_hook(opts)

          Repo.update_all(from(s in RevisionClockState, where: s.id == 1),
            set: [last_processed_date: today]
          )

          length(ids)
        else
          0
        end
      end,
      transaction_opts
    )
  end

  # Distinct shows with at least one episode whose air date falls strictly after
  # the watermark and no later than today. False-positive delivery (a show marked
  # for an air date a consumer happens not to care about) is acceptable; a missed
  # date is not, so both bounds are inclusive of the intended day.
  defp crossed_show_ids(from_date, today) do
    Episode
    |> where([e], not is_nil(e.media_item_id))
    |> where([e], e.air_date > ^from_date and e.air_date <= ^today)
    |> select([e], e.media_item_id)
    |> distinct(true)
    |> Repo.all()
  end

  defp after_mark_hook(opts) do
    case Keyword.get(opts, :after_mark) do
      hook when is_function(hook, 0) -> hook.()
      _ -> :ok
    end
  end
end
