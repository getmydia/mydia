defmodule Mydia.Repo.Migrations.MarkExistingTrashedFilesAsMissing do
  use Ecto.Migration

  @moduledoc """
  Stamps every already-trashed media file as "trashed while missing" so the
  newly-enabled byte deletion never touches a file at the library path.

  ## Why

  The trash system shipped in `bf4d1215` (v0.10.0, 2026-02-24) and until this
  branch `purge_old_trashed_media_files/1` was a bare `Repo.delete_all`: it
  dropped the row and deleted nothing from disk (#295). This branch turns byte
  deletion on, and it turns it on for the entire backlog those five months
  accumulated.

  That backlog is not mostly deliberate user deletes. `Mydia.Jobs.LibraryScanner`
  has been soft-trashing every file a scan finds missing since the same release,
  an entire library at a time when a network share is unmounted mid-scan. Those
  rows are indistinguishable at rest from a row whose file is genuinely still
  sitting at the library path - the distinction `Mydia.Library.TrashStore`
  records going forward simply did not exist when they were written.

  Without this backfill, the first `TrashCleanup` run after upgrading would
  permanently delete every file behind those rows, including files that have
  since come back because the share was remounted. Silent, total, irreversible.

  So every pre-existing trashed row gets the safe treatment. The cost is that
  #295's space reclamation only applies to files trashed *after* the upgrade;
  the backlog keeps occupying disk until an operator clears it by hand. For a
  feature whose failure mode is irreversible deletion of user media, that is the
  right way round.

  ## How

  `media_files.metadata` is a plain TEXT column holding JSON (see
  `Mydia.Library.FileMetadataType`), not a native JSON/JSONB column, so there is
  no portable single statement that can merge a key into it. Rows are read,
  decoded, merged and rewritten in Elixir, the same approach
  `20260628000000_unify_quality_profiles.exs` takes for the same reason.

  `Mydia.Library.Structs.FileMetadata.to_map/1` merges `extra` into the top
  level of the stored JSON rather than nesting it, so the marker is written as a
  top-level `"trashed_missing"` key. `from_map/1` routes it back into `extra`
  because it is not in the known-key whitelist. Every other key in the object is
  preserved untouched.

  ## Reversibility

  `down/0` removes the key. Note that it removes it from *all* trashed rows, not
  only the ones `up/0` added it to, because the two are indistinguishable
  afterwards. Roll this back only together with the code that reads the marker:
  rolling back the migration while keeping the new code would re-arm exactly the
  deletion this migration exists to prevent.
  """

  @marker "trashed_missing"

  def up, do: backfill(repo(), :mark)

  def down, do: backfill(repo(), :unmark)

  # Walks every trashed row and rewrites its metadata.
  #
  # Takes the repo explicitly rather than reading `repo()` from the migration
  # runner so the exact code path the migration runs can be exercised from a
  # test without standing up `Ecto.Migration.Runner`.
  @doc false
  @spec backfill(module(), :mark | :unmark) :: :ok
  def backfill(repo, direction) when direction in [:mark, :unmark] do
    %{rows: rows} =
      repo.query!("SELECT id, metadata FROM media_files WHERE trashed_at IS NOT NULL")

    sql = update_sql(repo)

    Enum.each(rows, fn [id, raw] ->
      current = decode(raw)

      updated =
        case direction do
          :mark -> mark(current)
          :unmark -> unmark(current)
        end

      if updated != current do
        repo.query!(sql, [Jason.encode!(updated), id])
      end
    end)

    :ok
  end

  # Adds the marker, unless the row already records where its bytes went.
  #
  # A row carrying "trashed_path" was written by the new code and its file
  # really is in the trash directory, so marking it missing would be a lie. It
  # cannot be a pre-existing row either, since nothing before this branch wrote
  # that key.
  @doc false
  @spec mark(map()) :: map()
  def mark(metadata) when is_map(metadata) do
    if Map.has_key?(metadata, "trashed_path") do
      metadata
    else
      Map.put(metadata, @marker, true)
    end
  end

  @doc false
  @spec unmark(map()) :: map()
  def unmark(metadata) when is_map(metadata), do: Map.delete(metadata, @marker)

  defp update_sql(repo) do
    if repo.__adapter__() == Ecto.Adapters.Postgres do
      "UPDATE media_files SET metadata = $1 WHERE id = $2"
    else
      "UPDATE media_files SET metadata = ? WHERE id = ?"
    end
  end

  defp decode(nil), do: %{}
  defp decode(""), do: %{}

  defp decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode(map) when is_map(map), do: map
  defp decode(_), do: %{}
end
