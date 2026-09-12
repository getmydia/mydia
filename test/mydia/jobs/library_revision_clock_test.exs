defmodule Mydia.Jobs.LibraryRevisionClockTest do
  @moduledoc """
  The daily Oban wrapper around the clock sweep.

  Nothing here re-tests the sweep itself; it verifies that the scheduled job is
  the sweep's production entry point and reports what it did.
  """

  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Mydia.Jobs.LibraryRevisionClock
  alias Mydia.LibraryApi.{MediaItemRevision, RevisionClockState}
  alias Mydia.Repo

  # async: false — this raises the *global* Logger level to :info so the worker's
  # `Logger.info` arguments are actually evaluated. The rest of the suite runs at
  # :warning (config/test.exs), where the Logger macro skips its arguments.
  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  test "advances the watermark and the crossed show's marker, logging the count" do
    watermark = Date.add(Date.utc_today(), -1)

    Repo.update_all(from(s in RevisionClockState, where: s.id == 1),
      set: [last_processed_date: watermark]
    )

    show = insert(:tv_show)
    insert(:episode, media_item: show, air_date: Date.utc_today())
    before = Repo.get_by!(MediaItemRevision, media_item_id: show.id).revision

    log = capture_log(fn -> assert perform_job(LibraryRevisionClock, %{}) == :ok end)

    assert Repo.get!(RevisionClockState, 1).last_processed_date == Date.utc_today()
    assert Repo.get_by!(MediaItemRevision, media_item_id: show.id).revision > before
    assert log =~ "marked 1 media item"
  end
end
