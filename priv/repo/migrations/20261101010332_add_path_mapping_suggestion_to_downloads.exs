defmodule Mydia.Repo.Migrations.AddPathMappingSuggestionToDownloads do
  use Ecto.Migration

  # The suggested remote-to-local mapping for a path_mapping_mismatch failure,
  # computed once when the import fails instead of on every Issues-tab render
  # (#1315). path_mapping_searched_at marks that the search ran, match or not,
  # so the backfill never repeats a search that found nothing.
  def change do
    alter table(:downloads) do
      add :path_mapping_remote_prefix, :text
      add :path_mapping_local_prefix, :text
      add :path_mapping_searched_at, :utc_datetime
    end
  end
end
