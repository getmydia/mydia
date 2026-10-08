defmodule Mydia.Repo.Migrations.AllowManyRemoteCopiesPerItem do
  @moduledoc """
  Lets one local item map to several items on the same media server.

  Jellyfin users commonly keep a separate 4K library, so one movie is two
  Jellyfin items with independent played flags. One mapping per item meant the
  crawl kept whichever copy came last and dropped watches on the other
  (getmydia/mydia#1079). Uniqueness moves to (item, remote_id).
  """
  use Ecto.Migration

  def up do
    drop index(:remote_item_mappings, [:provider, :provider_instance_id, :media_item_id],
           name: :remote_item_mappings_movie_index
         )

    drop index(:remote_item_mappings, [:provider, :provider_instance_id, :episode_id],
           name: :remote_item_mappings_episode_index
         )

    create unique_index(
             :remote_item_mappings,
             [:provider, :provider_instance_id, :media_item_id, :remote_id],
             name: :remote_item_mappings_movie_copy_index
           )

    create unique_index(
             :remote_item_mappings,
             [:provider, :provider_instance_id, :episode_id, :remote_id],
             name: :remote_item_mappings_episode_copy_index
           )
  end

  def down do
    # The old indexes allow one row per item. Keep the most recently seen copy.
    execute("""
    DELETE FROM remote_item_mappings
    WHERE id IN (
      SELECT older.id
      FROM remote_item_mappings older
      JOIN remote_item_mappings newer
        ON newer.provider = older.provider
       AND newer.provider_instance_id = older.provider_instance_id
       AND (newer.media_item_id = older.media_item_id OR newer.episode_id = older.episode_id)
       AND newer.id <> older.id
      WHERE COALESCE(newer.last_seen_at, newer.inserted_at) > COALESCE(older.last_seen_at, older.inserted_at)
         OR (COALESCE(newer.last_seen_at, newer.inserted_at) = COALESCE(older.last_seen_at, older.inserted_at)
             AND newer.id > older.id)
    )
    """)

    drop index(
           :remote_item_mappings,
           [:provider, :provider_instance_id, :media_item_id, :remote_id],
           name: :remote_item_mappings_movie_copy_index
         )

    drop index(:remote_item_mappings, [:provider, :provider_instance_id, :episode_id, :remote_id],
           name: :remote_item_mappings_episode_copy_index
         )

    create unique_index(:remote_item_mappings, [:provider, :provider_instance_id, :media_item_id],
             name: :remote_item_mappings_movie_index
           )

    create unique_index(:remote_item_mappings, [:provider, :provider_instance_id, :episode_id],
             name: :remote_item_mappings_episode_index
           )
  end
end
