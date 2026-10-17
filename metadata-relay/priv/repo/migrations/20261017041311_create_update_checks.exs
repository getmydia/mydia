defmodule MetadataRelay.Repo.Migrations.CreateUpdateChecks do
  use Ecto.Migration

  def change do
    # One row per install per ISO week (keyed by that week's Monday). An
    # install that checks several times in a week updates its row rather than
    # adding one, so counting rows for a week counts distinct installs. No
    # address is stored.
    create table(:update_checks, primary_key: false) do
      add :install_id, :text, null: false
      add :week, :date, null: false
      add :version, :text, null: false
      add :arch, :text, null: false
      add :db, :text, null: false
      add :checked_at, :utc_datetime, null: false
    end

    create unique_index(:update_checks, [:install_id, :week])
    create index(:update_checks, [:week])
  end
end
