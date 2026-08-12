defmodule Mydia.Repo.Migrations.GeneralizeMediaServerUserLinks do
  use Ecto.Migration

  @moduledoc """
  A link identifies a Mydia user's account on any media server, not only Plex.
  Jellyfin identifies users by GUID and issues no per-user token, so the
  Plex-specific column names no longer describe what they hold.

  `rename/3` for a column is supported by both SQLite and PostgreSQL, so this
  needs no adapter branch.
  """

  def change do
    rename table(:media_server_user_links), :plex_account_id, to: :remote_user_id
    rename table(:media_server_user_links), :plex_username, to: :remote_username
  end
end
