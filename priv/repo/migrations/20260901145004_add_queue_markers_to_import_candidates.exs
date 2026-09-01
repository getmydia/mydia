defmodule Mydia.Repo.Migrations.AddQueueMarkersToImportCandidates do
  use Ecto.Migration

  # The user's intent to accept or re-match a group is durable state on the
  # candidate row, not an Oban argument. A worker keyed on library_path_id
  # discovers its own work from these columns, so a restart mid-drain resumes
  # and a second click while a drain is running simply marks more rows.
  def change do
    alter table(:import_candidates) do
      add :queued_op, :text
      add :queued_at, :utc_datetime
      add :queue_error, :text
    end

    # Partial: the overwhelming majority of rows carry no marker, and every
    # reader of this column filters on `queued_op IS NOT NULL`. Supported on
    # both SQLite and PostgreSQL.
    create index(:import_candidates, [:library_path_id, :queued_op],
             where: "queued_op IS NOT NULL",
             name: :import_candidates_queued_op_index
           )
  end
end
