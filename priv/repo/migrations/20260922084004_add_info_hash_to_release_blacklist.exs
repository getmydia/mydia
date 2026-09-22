defmodule Mydia.Repo.Migrations.AddInfoHashToReleaseBlacklist do
  @moduledoc """
  Adds `info_hash` to `release_blacklist`, so a ban covers the torrent on every
  indexer that lists it and not only on the indexer it was grabbed from.

  Backfills rows whose guid is a bare 40-character hex string: Bitmagnet's guid
  is the torrent's v1 infohash. Rows keyed by a synthesized `sha256:` guid or
  an indexer URL stay NULL, since nothing in them recovers the torrent.

  The backfill reads guids and filters them in Elixir, then sets
  `info_hash = lower(guid)` by guid, so it runs unchanged on SQLite and
  PostgreSQL.
  """
  use Ecto.Migration

  import Ecto.Query

  def up do
    alter table(:release_blacklist) do
      add :info_hash, :text
    end

    create index(:release_blacklist, [:info_hash])

    flush()

    backfill(repo())
  end

  def down do
    drop index(:release_blacklist, [:info_hash])

    alter table(:release_blacklist) do
      remove :info_hash
    end
  end

  @doc false
  # Public so the migration test can run it against the sandboxed repo.
  def backfill(repo) do
    repo.all(from(b in "release_blacklist", select: b.guid))
    |> Enum.filter(&hex_info_hash?/1)
    |> Enum.chunk_every(500)
    |> Enum.each(fn guids ->
      repo.update_all(
        from(b in "release_blacklist",
          where: b.guid in ^guids,
          update: [set: [info_hash: fragment("lower(?)", b.guid)]]
        ),
        []
      )
    end)
  end

  defp hex_info_hash?(guid) when is_binary(guid),
    do: String.match?(guid, ~r/\A[0-9a-fA-F]{40}\z/)

  defp hex_info_hash?(_guid), do: false
end
