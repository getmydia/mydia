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

    # Partial: the overwhelming majority of rows carry no marker, and readers
    # of this column filter on it in both directions -- `is_nil(queued_op)`
    # for the pending view (`filter_status/2`, `count_pending/0`, and both
    # queue functions' UPDATE guards) and `not is_nil(queued_op)` for the
    # queued one -- so this partial index still covers the selective,
    # minority-row side of that split. Supported on both SQLite and
    # PostgreSQL.
    create index(:import_candidates, [:library_path_id, :queued_op],
             where: "queued_op IS NOT NULL",
             name: :import_candidates_queued_op_index
           )
  end
end
