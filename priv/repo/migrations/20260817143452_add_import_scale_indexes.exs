defmodule Mydia.Repo.Migrations.AddImportScaleIndexes do
  use Ecto.Migration

  def change do
    # Jobs.ImportRun.insert_batch/3 calls list_media_files_by_relative_path/3
    # once per scanned file against a column with no index.
    create index(:media_files, [:library_path_id, :relative_path])

    # The inbox predicate. Partial index syntax is valid on SQLite >= 3.8 and
    # on PostgreSQL.
    create index(:media_files, [:library_path_id],
             where: "media_item_id IS NULL AND episode_id IS NULL AND trashed_at IS NULL",
             name: :media_files_unresolved_idx
           )

    create index(:media_file_match_candidates, [:provider_id])
    create index(:media_file_match_candidates, [:media_file_id, :rank, :confidence])

    # Carried forward from Task 3's review. The three indexes created with
    # import_groups do not fully serve ImportGroups.page/2: neither ordering
    # index carries `id`, so groups tied on file_count need an extra sort step,
    # and no index touches provider_id, which the :no_match band filters on.
    create index(:import_groups, [:library_path_id, :status, :file_count, :id])
    create index(:import_groups, [:library_path_id, :status, :provider_id])
  end
end
