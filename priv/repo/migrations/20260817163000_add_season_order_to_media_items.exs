defmodule Mydia.Repo.Migrations.AddSeasonOrderToMediaItems do
  use Ecto.Migration

  def change do
    alter table(:media_items) do
      # Nullable on purpose, with no default. NULL means "never asked", which
      # is what the suggestion banner keys on; an explicit "official" means the
      # user was offered a split and chose aired order.
      add :season_order, :text
    end
  end
end
