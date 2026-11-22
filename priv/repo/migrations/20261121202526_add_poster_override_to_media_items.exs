defmodule Mydia.Repo.Migrations.AddPosterOverrideToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      add :poster_override, :text
    end
  end
end
