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

  # Deliberately a no-op. `up/0` does not record which rows it changed, so
  # disabling everything on the way down would switch off installs that were
  # enabled before this ever ran. Rolling back leaves remote access as it is;
  # turn it off from Settings > Remote Access if that is what you want.
  def down, do: :ok
end
