defmodule Mydia.Repo.Migrations.UnhideMissingRowsWithTrashedBytes do
  use Ecto.Migration

  @moduledoc """
  Clears `trashed_reason` on rows marked `:missing` whose bytes were in fact
  moved into the trash directory.

  ## Why

  The library scanner trashed every file its listing called missing with the
  default `move: true`. A file that reappeared between the listing and the
  trashing (a reconnecting mount, a concurrent import) was moved into
  `.mydia-trash/` on a row stamped `:missing`, with
  `metadata.extra["trashed_path"]` pointing at the moved bytes.

  `:missing` rows are now hidden from the trash page, and a reappearing file
  can never restore such a row because its bytes are no longer at the library
  path. `TrashCleanup` would then purge real media nobody was shown. Clearing
  the reason makes the trash page render these rows as "Unknown", so they are
  visible and an operator can restore or purge them.

  ## How

  `media_files.metadata` is a TEXT column holding JSON, so the rows are read,
  decoded and checked in Elixir rather than with an adapter-specific JSON
  predicate, the approach
  `20260731120000_mark_existing_trashed_files_as_missing.exs` takes for the
  same reason. Only `id` and `metadata` are selected, never the whole schema
  (see priv/repo/README.md).

  ## Reversibility

  `down/0` does nothing. The old reason is not recoverable from the row, and
  restoring it would hide the rows again.
  """

  def up, do: unhide(repo())

  def down, do: :ok

  # Takes the repo explicitly so a test can run the exact code path the
  # migration runs without standing up Ecto.Migration.Runner.
  @doc false
  @spec unhide(module()) :: :ok
  def unhide(repo) do
    %{rows: rows} =
      repo.query!(
        "SELECT id, metadata FROM media_files " <>
          "WHERE trashed_at IS NOT NULL AND trashed_reason = 'missing'"
      )

    sql = update_sql(repo)

    rows
    |> Enum.filter(fn [_id, raw] -> holds_trash_copy?(decode(raw)) end)
    |> Enum.each(fn [id, _raw] -> repo.query!(sql, [id]) end)

    :ok
  end

  # FileMetadata.to_map/1 merges `extra` into the top level of the stored
  # JSON, so the key sits at the top level.
  @doc false
  @spec holds_trash_copy?(map()) :: boolean()
  def holds_trash_copy?(%{"trashed_path" => path}) when is_binary(path) and path != "", do: true
  def holds_trash_copy?(_metadata), do: false

  defp update_sql(repo) do
    if repo.__adapter__() == Ecto.Adapters.Postgres do
      "UPDATE media_files SET trashed_reason = NULL WHERE id = $1"
    else
      "UPDATE media_files SET trashed_reason = NULL WHERE id = ?"
    end
  end

  defp decode(raw) when is_binary(raw) and raw != "" do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode(map) when is_map(map), do: map
  defp decode(_), do: %{}
end
