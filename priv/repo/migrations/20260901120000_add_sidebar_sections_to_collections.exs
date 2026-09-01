defmodule Mydia.Repo.Migrations.AddSidebarSectionsToCollections do
  use Ecto.Migration

  def change do
    alter table(:collections) do
      add :pinned_position, :integer
      add :sidebar_icon, :text
      add :exclusive, :boolean, default: false, null: false
    end

    create index(:collections, [:user_id, :pinned_position])
  end
end
