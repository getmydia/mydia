defmodule Mydia.Repo.Migrations.DropImportSessions do
  use Ecto.Migration

  def up do
    # The four-step wizard stored its entire state in one JSON blob here and
    # rewrote it on every checkbox toggle, which is what made a large library
    # impossible to review. Progress now lives in media_files and
    # media_file_match_candidates, which are written incrementally.
    #
    # In-flight rows are discarded deliberately. They expired after 24 hours
    # anyway, and rescanning rebuilds everything they held.
    drop table(:import_sessions)
  end

  def down do
    create table(:import_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      add :step, :text, default: "select_path"
      add :status, :text, default: "active"
      add :scan_path, :text
      add :session_data, :text
      add :scan_stats, :text
      add :import_progress, :text
      add :import_results, :text
      add :completed_at, :utc_datetime
      add :expires_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end
end
