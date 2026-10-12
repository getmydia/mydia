defmodule Mydia.Repo.Migrations.RefreshWatchSyncMappingInsertedAtTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.WatchSync.Mapping

  # Migration modules are not compiled into the app, so load the file
  # explicitly. Guarded because the test alias may already have loaded it
  # through ecto.migrate in this VM.
  unless Code.ensure_loaded?(Mydia.Repo.Migrations.RefreshWatchSyncMappingInsertedAt) do
    Code.require_file(
      "priv/repo/migrations/20261012195307_refresh_watch_sync_mapping_inserted_at.exs"
    )
  end

  alias Mydia.Repo.Migrations.RefreshWatchSyncMappingInsertedAt

  test "every existing mapping looks newly added" do
    movie = media_item_fixture()
    a_week_ago = DateTime.utc_now() |> DateTime.add(-7, :day) |> DateTime.truncate(:second)

    mapping =
      Repo.insert!(%Mapping{
        provider: "jellyfin",
        provider_instance_id: "inst-backfill",
        media_item_id: movie.id,
        remote_id: "rk-old",
        last_seen_at: a_week_ago,
        inserted_at: a_week_ago,
        updated_at: a_week_ago
      })

    before = DateTime.utc_now() |> DateTime.truncate(:second)
    assert :ok = RefreshWatchSyncMappingInsertedAt.backfill()

    reloaded = Repo.get!(Mapping, mapping.id)
    assert DateTime.compare(reloaded.inserted_at, before) != :lt
    assert reloaded.last_seen_at == a_week_ago
  end
end
