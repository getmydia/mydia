defmodule Mydia.Repo.Migrations.UniqueRemoteAccountPerMediaServer do
  use Ecto.Migration

  @moduledoc """
  One remote account belongs to at most one Mydia user per media server.

  Two links naming the same account each run a watched sync against it, so both
  Mydia users import that one account's history. `Settings.upsert_media_server_user_link/1`
  refuses it in the single write path; this index is the floor under that, for
  races and for anything that reaches the table another way.

  `remote_user_id` is nullable and Plex's owner fallback legitimately writes a
  link without one, so the index is partial. NULLs already compare as distinct in
  a unique index on both SQLite and PostgreSQL; the predicate says so out loud
  and survives a future change to that default.

  The DELETE first is a no-op on any install whose links Mydia itself created
  (username matching cannot produce two links on one account, and the owner
  fallback has no `remote_user_id`), but a hand-edited row would otherwise fail
  the index and leave the deploy unable to migrate. Where duplicates do exist the
  oldest link wins, since the newer one is the accidental claim. The statement is
  plain correlated-subquery SQL that both adapters accept, so it needs no branch.
  """

  @index_name :media_server_user_links_config_remote_user_index

  def up do
    execute """
    DELETE FROM media_server_user_links
    WHERE remote_user_id IS NOT NULL
      AND EXISTS (
        SELECT 1
        FROM media_server_user_links older
        WHERE older.media_server_config_id = media_server_user_links.media_server_config_id
          AND older.remote_user_id = media_server_user_links.remote_user_id
          AND (older.inserted_at < media_server_user_links.inserted_at
               OR (older.inserted_at = media_server_user_links.inserted_at
                   AND older.user_id < media_server_user_links.user_id))
      )
    """

    create unique_index(
             :media_server_user_links,
             [:media_server_config_id, :remote_user_id],
             where: "remote_user_id IS NOT NULL",
             name: @index_name
           )
  end

  def down do
    drop_if_exists index(:media_server_user_links, [:media_server_config_id, :remote_user_id],
                     name: @index_name
                   )
  end
end
