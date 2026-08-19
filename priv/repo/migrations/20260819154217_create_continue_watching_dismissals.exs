defmodule Mydia.Repo.Migrations.CreateContinueWatchingDismissals do
  use Ecto.Migration

  def change do
    # One row per title a viewer has taken off the Continue Watching rail.
    #
    # Keyed on the media item, which for a series means the show and not the
    # episode. The rail carries at most one card per show, so the show is the
    # only unit a "remove this card" gesture can honestly mean; dismissing a
    # single episode would put the show straight back with the next one.
    #
    # Note this is a hide, not an unwatch. The `playback_progress` row is left
    # alone so the resume point survives, and no `playback.unwatched` event is
    # emitted, which is what keeps `Mydia.WatchSync` from telling Plex or
    # Jellyfin that a title nobody unwatched was unwatched.
    create table(:continue_watching_dismissals, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :media_item_id, references(:media_items, type: :binary_id, on_delete: :delete_all),
        null: false

      # Compared against the entry's most recent watch time rather than being
      # a plain boolean flag. A later play pushes that time past this stamp
      # and the title returns on its own, so nothing has to sweep this table.
      add :dismissed_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    # One dismissal per viewer per title, which is also what lets a repeat
    # dismissal be an atomic upsert instead of a read-modify-write.
    create unique_index(:continue_watching_dismissals, [:user_id, :media_item_id])
  end
end
