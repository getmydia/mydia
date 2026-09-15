defmodule Mydia.Repo.Migrations.AddRemovalStateToDownloads do
  use Ecto.Migration

  # An operator-requested removal runs in Mydia.Jobs.RemoveDownload. These
  # columns hold its intent and outcome on the row, so the page can show the row
  # as being removed the moment the click lands, and a retry needs nothing from
  # the job that gave up.
  def change do
    alter table(:downloads) do
      add :removal_requested_at, :utc_datetime
      add :removal_kind, :text
      add :removal_delete_files, :boolean, default: false, null: false
      add :removal_error, :text
    end
  end
end
