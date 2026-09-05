defmodule Mydia.Repo.Migrations.ScopeProviderIdsByMediaType do
  use Ecto.Migration

  def up do
    # Drop legacy single-column unique indexes on media_items
    drop_if_exists index(:media_items, [:tmdb_id], name: :media_items_tmdb_id_index)
    drop_if_exists index(:media_items, [:tvdb_id], name: :media_items_tvdb_id_index)
    drop_if_exists index(:media_items, [:tvdb_id], name: :media_items_tvdb_id_unique_index)

    # Add composite partial unique indexes on media_items
    create unique_index(:media_items, [:type, :tmdb_id],
             where: "tmdb_id IS NOT NULL",
             name: :media_items_type_tmdb_id_unique_index
           )

    create unique_index(:media_items, [:type, :tvdb_id],
             where: "tvdb_id IS NOT NULL",
             name: :media_items_type_tvdb_id_unique_index
           )

    # Add query indexes on media_requests
    create index(:media_requests, [:media_type, :tmdb_id, :status],
             name: :media_requests_type_tmdb_id_status_index
           )

    create index(:media_requests, [:media_type, :tvdb_id, :status],
             name: :media_requests_type_tvdb_id_status_index
           )
  end

  def down do
    drop_if_exists index(:media_requests, [:media_type, :tvdb_id, :status],
                     name: :media_requests_type_tvdb_id_status_index
                   )

    drop_if_exists index(:media_requests, [:media_type, :tmdb_id, :status],
                     name: :media_requests_type_tmdb_id_status_index
                   )

    drop_if_exists index(:media_items, [:type, :tvdb_id],
                     name: :media_items_type_tvdb_id_unique_index
                   )

    drop_if_exists index(:media_items, [:type, :tmdb_id],
                     name: :media_items_type_tmdb_id_unique_index
                   )

    create unique_index(:media_items, [:tmdb_id], name: :media_items_tmdb_id_index)

    create unique_index(:media_items, [:tvdb_id],
             where: "tvdb_id IS NOT NULL",
             name: :media_items_tvdb_id_index
           )
  end
end
