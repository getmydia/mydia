defmodule Mydia.Repo.Migrations.RenameNzbhydra2IndexerTypeToNewznab do
  use Ecto.Migration

  # `nzbhydra2` was the concrete name of what is now the generic Newznab
  # adapter. Rewrite stored rows to the canonical type at upgrade time; the
  # configuration loader maps any remaining legacy value, so this only has to
  # be a straight type swap. Plain SQL works on both SQLite and PostgreSQL.
  def up do
    execute("UPDATE indexer_configs SET type = 'newznab' WHERE type = 'nzbhydra2'")
  end

  def down do
    execute("UPDATE indexer_configs SET type = 'nzbhydra2' WHERE type = 'newznab'")
  end
end
