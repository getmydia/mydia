defmodule Mydia.Repo.Migrations.AddOriginToPlaybackProgress do
  use Ecto.Migration

  # The origin of the last write to a progress row ("player", "sync:<provider>",
  # "plugin:<slug>" or "plugin:<slug>:<instance_id>"). Until now origin only
  # rode on events, so a plugin paging progress with data-list could not tell
  # its own write-backs from a user's. Null for rows written before this column.
  def change do
    alter table(:playback_progress) do
      add :last_write_origin, :text
    end
  end
end
