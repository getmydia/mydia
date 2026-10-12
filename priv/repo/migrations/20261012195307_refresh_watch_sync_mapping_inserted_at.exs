defmodule Mydia.Repo.Migrations.RefreshWatchSyncMappingInsertedAt do
  use Ecto.Migration
  import Ecto.Query

  @moduledoc """
  Stamps every watch-sync mapping as newly added.

  The engine lists a user's whole library once whenever a mapping was added
  since that user's last successful run, which is how a copy mapped after its
  watch was listed finally gets reconciled (#1097). Installs that already
  crawled the missing copies did so before that rule existed, so their
  mappings look old and would never trigger it. Restamping them gives every
  linked user one full listing on the next run.
  """

  # Irreversible by design: the original insert times carry no meaning the
  # sync relies on, and restoring them is not possible.
  def up, do: backfill()
  def down, do: :ok

  @doc false
  def backfill do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(m in "remote_item_mappings",
      update: [set: [inserted_at: type(^now, :utc_datetime)]]
    )
    |> query_repo().update_all([])

    :ok
  end

  # `repo/0` from Ecto.Migration only works inside a migration runner. Tests
  # call `backfill/0` directly, so fall back to Mydia.Repo outside that context.
  defp query_repo do
    case Process.get(:ecto_migration) do
      %{runner: _} -> repo()
      _ -> Mydia.Repo
    end
  end
end
