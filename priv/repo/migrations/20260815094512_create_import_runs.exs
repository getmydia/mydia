defmodule Mydia.Repo.Migrations.CreateImportRuns do
  use Ecto.Migration

  def change do
    # One row per user-started import. This is the handle Stop writes to and
    # the coordinator polls between chunks, which is what makes stopping a
    # cooperative handoff rather than a killed process.
    create table(:import_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :library_path_id,
          references(:library_paths, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      # :review caches candidates and links nothing. :unattended additionally
      # links every confident match as it goes.
      add :mode, :text, null: false, default: "review"

      add :status, :text, null: false, default: "running"
      add :phase, :text, null: false, default: "scanning"

      add :files_discovered, :integer, null: false, default: 0
      add :files_matched, :integer, null: false, default: 0
      add :files_linked, :integer, null: false, default: 0

      add :current_file, :text
      add :error, :text

      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:import_runs, [:library_path_id])

    # A partial unique index rather than an application-level check, so two
    # browser tabs pressing Start at the same moment cannot both win. SQLite has
    # supported partial indexes since 3.8, so this is portable across both
    # adapters. 'stopping' counts as active: the coordinator is still draining.
    create unique_index(:import_runs, [:library_path_id],
             where: "status IN ('running', 'stopping')",
             name: :import_runs_one_active_per_library_path
           )
  end
end
