defmodule Mydia.Repo.Migrations.RetireSkippedImportListItemStatus do
  use Ecto.Migration

  # "skipped" was only ever written by a reconciler with no production caller.
  # Items in it become pending; whether they are already in the library is
  # now computed when items are read.
  def up do
    execute("""
    UPDATE import_list_items
    SET status = 'pending', skip_reason = NULL
    WHERE status = 'skipped'
    """)
  end

  def down, do: :ok
end
