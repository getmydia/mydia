defmodule Mydia.Repo.Migrations.CreateSmartSpaceTables do
  @moduledoc """
  Per-show Smart Space overrides and keeps.

  Keeps are unique per level (show, season, episode). A single composite unique
  index on `(media_item_id, season_number, episode_id)` cannot do this, because
  NULLs compare as distinct on both SQLite and PostgreSQL, so a show keep (two
  NULLs) or a season keep (NULL episode) would never collide. Instead there is
  one partial unique index per level; partial indexes behave the same on both
  adapters. `Mydia.SmartSpace.Rules.keep/2` also looks up before inserting, so
  a duplicate returns the existing row rather than a constraint error.
  """

  use Ecto.Migration

  def change do
    create table(:smart_space_overrides, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :media_item_id, references(:media_items, type: :binary_id, on_delete: :delete_all),
        null: false

      add :mode, :text, null: false
      add :unit, :text
      add :grace_days, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:smart_space_overrides, [:media_item_id])

    create table(:smart_space_keeps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :media_item_id, references(:media_items, type: :binary_id, on_delete: :delete_all),
        null: false

      add :season_number, :integer
      add :episode_id, references(:episodes, type: :binary_id, on_delete: :delete_all)
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:smart_space_keeps, :smart_space_keeps_one_level,
             check: "season_number IS NULL OR episode_id IS NULL"
           )

    create index(:smart_space_keeps, [:media_item_id])

    create unique_index(:smart_space_keeps, [:media_item_id],
             where: "season_number IS NULL AND episode_id IS NULL",
             name: :smart_space_keeps_show_index
           )

    create unique_index(:smart_space_keeps, [:media_item_id, :season_number],
             where: "season_number IS NOT NULL",
             name: :smart_space_keeps_season_index
           )

    create unique_index(:smart_space_keeps, [:episode_id],
             where: "episode_id IS NOT NULL",
             name: :smart_space_keeps_episode_index
           )
  end
end
