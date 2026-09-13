defmodule Mydia.LibraryApi.RevisionClockTest do
  @moduledoc """
  The UTC-day clock sweep.

  A show's availability is derived from its episodes' `air_date`, so the change
  happens with no database write for a trigger to observe. The sweep is the only
  thing that advances those markers, and it must move the watermark and the
  markers atomically: a crash between the two would either lose a day's
  transitions or re-deliver a day forever.
  """

  use Mydia.DataCase, async: false

  import Ecto.Query

  alias Mydia.LibraryApi.{MediaItemRevision, RevisionClock, RevisionClockState}
  alias Mydia.Repo

  # The watermark the migration seeded to a fixed day so the interval is
  # deterministic rather than relative to the wall clock.
  @watermark ~D[2026-09-01]
  @today ~D[2026-09-12]

  setup do
    Repo.update_all(from(s in RevisionClockState, where: s.id == 1),
      set: [last_processed_date: @watermark]
    )

    :ok
  end

  defp marker!(media_item_id), do: Repo.get_by!(MediaItemRevision, media_item_id: media_item_id)

  defp show_with_episode(air_date) do
    show = insert(:tv_show)
    insert(:episode, media_item: show, air_date: air_date)
    show
  end

  test "marks shows whose episode air date crossed the watermark and advances it" do
    # Exactly on the watermark is not crossed: the lower bound is strict.
    past_show = show_with_episode(@watermark)
    # Inside the interval.
    crossed_show = show_with_episode(~D[2026-09-05])
    # Exactly on today is crossed: the upper bound is inclusive.
    crossed_today_show = show_with_episode(@today)
    # After today is not crossed.
    future_show = show_with_episode(~D[2026-09-13])

    past_before = marker!(past_show.id).revision
    crossed_before = marker!(crossed_show.id).revision
    crossed_today_before = marker!(crossed_today_show.id).revision
    future_before = marker!(future_show.id).revision

    assert {:ok, 2} = RevisionClock.catch_up(@today)
    assert Repo.get!(RevisionClockState, 1).last_processed_date == @today

    assert marker!(crossed_show.id).revision > crossed_before
    assert marker!(crossed_today_show.id).revision > crossed_today_before
    assert marker!(past_show.id).revision == past_before
    assert marker!(future_show.id).revision == future_before

    # A second sweep on the same day has nothing left to do.
    assert {:ok, 0} = RevisionClock.catch_up(@today)
  end

  test "a failure after marking rolls back both the markers and the watermark" do
    crossed_show = show_with_episode(~D[2026-09-05])
    crossed_before = marker!(crossed_show.id).revision

    assert {:error, :forced} =
             RevisionClock.catch_up(@today, after_mark: fn -> Repo.rollback(:forced) end)

    assert marker!(crossed_show.id).revision == crossed_before
    assert Repo.get!(RevisionClockState, 1).last_processed_date == @watermark
  end
end
