defmodule Mydia.Repo.Migrations.PurgeFalseAutoRejectBlacklistTest do
  use Mydia.DataCase, async: true

  import Ecto.Query

  alias Mydia.Downloads.ReleaseBlacklist
  alias Mydia.Repo

  @cutoff ~U[2026-08-07 00:00:00.000000Z]

  # Mirrors the migration's DELETE predicate exactly.
  defp purge do
    {count, _} =
      Repo.delete_all(
        from b in ReleaseBlacklist,
          where: b.failure_reason == "rejected_by_user" and b.inserted_at >= ^@cutoff
      )

    count
  end

  defp insert_row(reason, inserted_at) do
    Repo.insert!(%ReleaseBlacklist{
      indexer: "1337x",
      guid: "guid-#{System.unique_integer([:positive])}",
      title: "Some Release",
      failure_reason: reason,
      inserted_at: inserted_at,
      expires_at: DateTime.add(inserted_at, 30, :day)
    })
  end

  test "deletes rejected_by_user rows written on or after the cutoff" do
    row = insert_row("rejected_by_user", ~U[2026-08-09 12:00:00.000000Z])

    assert purge() == 1
    refute Repo.get(ReleaseBlacklist, row.id)
  end

  test "keeps rejected_by_user rows written before the cutoff" do
    row = insert_row("rejected_by_user", ~U[2026-08-01 12:00:00.000000Z])

    assert purge() == 0
    assert Repo.get(ReleaseBlacklist, row.id)
  end

  test "keeps rows with any other failure reason regardless of date" do
    row = insert_row("stalled", ~U[2026-08-09 12:00:00.000000Z])

    assert purge() == 0
    assert Repo.get(ReleaseBlacklist, row.id)
  end
end
