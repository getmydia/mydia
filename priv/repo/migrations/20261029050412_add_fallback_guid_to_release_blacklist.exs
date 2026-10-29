defmodule Mydia.Repo.Migrations.AddFallbackGuidToReleaseBlacklist do
  @moduledoc """
  Adds `fallback_guid` to `release_blacklist`: the mirror-independent
  `sha256:` key of `(indexer, title, size)` for the banned release.

  A Cardigann guid is the resolved download URL, which changes when the
  definition fails over to another mirror or the link carries a session
  token. Recording the fallback key on the same row lets the ban still match
  the release, without a second row the admin page would show and an
  un-ban would miss.

  Existing rows stay NULL. Their guid is either already the fallback key or an
  indexer's own guid, and lookups compare a result's fallback key against the
  guid column too.
  """
  use Ecto.Migration

  def change do
    alter table(:release_blacklist) do
      add :fallback_guid, :text
    end

    create index(:release_blacklist, [:indexer, :fallback_guid])
  end
end
