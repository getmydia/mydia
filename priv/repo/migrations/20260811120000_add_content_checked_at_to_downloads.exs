defmodule Mydia.Repo.Migrations.AddContentCheckedAtToDownloads do
  use Ecto.Migration

  # Purely additive: one new column. No ALTER COLUMN, so this needs no
  # SQLite/Postgres branching.
  #
  # Stamped once DownloadMonitor has successfully enumerated a torrent's
  # files, so the pre-completion content check costs at most one client
  # request per download for its entire lifetime rather than one per poll.
  def change do
    alter table(:downloads) do
      add :content_checked_at, :utc_datetime
    end
  end
end
