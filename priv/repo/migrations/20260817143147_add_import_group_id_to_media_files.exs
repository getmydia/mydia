defmodule Mydia.Repo.Migrations.AddImportGroupIdToMediaFiles do
  use Ecto.Migration

  # Adding a nullable column with a FK is an additive ALTER on both adapters, so
  # no table rebuild is needed here.
  #
  # Do NOT restore unique_index(:media_files, [:path]). It looks like
  # 20260322000000_fix_episode_cascade_deletes.exs accidentally dropped it during
  # a SQLite table rebuild, but it did not: 20251115185757_make_media_files_path_nullable.exs
  # deliberately dropped that index on both adapters when `path` became nullable.
  # In production every media_files row has path: nil, so the index guards
  # nothing real even where it exists. Re-adding it breaks
  # Mydia.Jobs.MediaImportTest's duplicate_media_file_scenario/1, which
  # intentionally creates two media_files rows with the same path.
  def change do
    alter table(:media_files) do
      add :import_group_id,
          references(:import_groups, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:media_files, [:import_group_id])
  end
end
