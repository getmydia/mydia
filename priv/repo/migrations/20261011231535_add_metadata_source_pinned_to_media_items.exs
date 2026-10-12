defmodule Mydia.Repo.Migrations.AddMetadataSourcePinnedToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :metadata_source_pinned, :boolean, null: false, default: false
    end
  end
end
