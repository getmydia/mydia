defmodule Mydia.Repo.Migrations.AddImportGroupIdToMediaFiles do
  use Ecto.Migration

  # Adding a nullable column with a FK is an additive ALTER on both adapters, so
  # no table rebuild is needed here. That matters: migration
  # 20260322000000_fix_episode_cascade_deletes.exs rebuilt media_files on SQLite
  # and silently dropped unique_index(:media_files, [:path]). This migration
  # restores that index rather than risking another rebuild.
  def change do
    alter table(:media_files) do
      add :import_group_id,
          references(:import_groups, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:media_files, [:import_group_id])

    create_if_not_exists unique_index(:media_files, [:path], name: :media_files_path_index)
  end
end
