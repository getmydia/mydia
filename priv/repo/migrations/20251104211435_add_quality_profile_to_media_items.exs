defmodule Mydia.Repo.Migrations.AddQualityProfileToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :quality_profile_id,
          references(:quality_profiles, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:media_items, [:quality_profile_id])
  end
end
