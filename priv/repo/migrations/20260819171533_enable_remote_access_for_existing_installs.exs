defmodule Mydia.Repo.Migrations.EnableRemoteAccessForExistingInstalls do
  @moduledoc """
  Turns remote access on for every install that already has a config row.

  The `enabled` column was never enforced: it was read in exactly one template
  to decide whether the pairing card rendered, while the p2p node ran and served
  paired devices regardless. A stored `false` therefore records what an operator
  clicked, not how the server behaved, and honoring it now would silently cut off
  working remote players on upgrade. Preserving observed behavior and letting
  operators make a real choice against a switch that works is the safer default.

  The column's DB-level default is deliberately left alone. Inserts all go
  through Ecto, whose schema default changes alongside this migration, and
  altering a column default on SQLite means rebuilding the table.
  """

  use Ecto.Migration

  import Mydia.Repo.Migrations.Helpers

  def up do
    execute_update(:remote_access_config, enabled: true)
  end

  def down do
    execute_update(:remote_access_config, enabled: false)
  end
end
