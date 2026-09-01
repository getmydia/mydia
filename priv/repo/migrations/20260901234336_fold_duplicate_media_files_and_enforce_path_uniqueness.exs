defmodule Mydia.Repo.Migrations.FoldDuplicateMediaFilesAndEnforcePathUniqueness do
  use Ecto.Migration

  require Logger

  alias Mydia.Repo.Migrations.Helpers

  # Nothing ever stopped two media_files rows describing one physical file.
  # The original unique_index(:media_files, [:path]) went away when `path` was
  # superseded and was deliberately not restored, and import_candidates got a
  # unique index on (library_path_id, relative_path) while media_files never
  # did. The re-scan then read the extra row as a file missing from disk and
  # trashed it, which physically moved the bytes out of the library (#653).
  #
  # Rows are grouped by canonical absolute path rather than by the index
  # columns, so two library paths over the same tree (a bind mount, a symlink,
  # a trailing slash) fold together even though the index cannot express that.
  #
  # Losers are deleted outright rather than marked trashed.
  # Library.purge_old_trashed_media_files/1 treats a trashed row carrying
  # neither "trashed_path" nor "trashed_missing" in its metadata as legacy and
  # deletes the file at its library path once retention expires, so soft
  # trashing here would schedule the operator's real files for deletion 30
  # days out. Deleting the row touches no bytes at all.

  # Dependents of media_files, each with the columns its unique index carries
  # alongside media_file_id. Moving a loser's dependent onto the winner
  # collides where the winner already holds that key, so every UPDATE is
  # guarded and whatever could not move is deleted with the loser.
  #
  # transcode_jobs is unique on (media_file_id, resolution) only WHERE
  # type = 'download'. Guarding on (resolution, type) is stricter than the
  # index, which at worst drops a non-download job that could have moved.
  @dependents [
    {"subtitles", ["subtitle_hash"]},
    {"media_hashes", []},
    {"subtitle_track_settings", ["track_ref"]},
    {"transcode_jobs", ["resolution", "type"]},
    {"media_segments", ["type"]},
    {"media_file_match_candidates", ["rank"]}
  ]

  def up do
    fold_duplicates()
  end

  # The fold is not reversible: the losing rows are gone. Rolling back only
  # lifts the constraint.
  def down, do: :ok

  defp fold_duplicates do
    %{rows: rows} =
      repo().query!(
        """
        SELECT mf.id, lp.path, mf.relative_path, mf.inserted_at
        FROM media_files mf
        JOIN library_paths lp ON lp.id = mf.library_path_id
        WHERE mf.trashed_at IS NULL AND mf.relative_path IS NOT NULL
        """,
        []
      )

    # A relative library root cannot be canonicalized without knowing the
    # working directory the migration happened to run in, and folding on a
    # guessed path would delete rows for files that are not actually the same
    # file. Rows whose root is not absolute are excluded from folding
    # entirely rather than trusted; nothing in
    # lib/mydia/settings/library_path.ex enforces that library_paths.path is
    # absolute, so this cannot be assumed away.
    {foldable, skipped} =
      Enum.split_with(rows, fn [_id, library_root, _relative_path, _inserted_at] ->
        Path.type(library_root) == :absolute
      end)

    if skipped != [] do
      Logger.warning(
        "fold_duplicate_media_files_and_enforce_path_uniqueness: skipped #{length(skipped)} " <>
          "media_files row(s) whose library_paths.path is not absolute; they were not " <>
          "considered for duplicate folding"
      )
    end

    foldable
    |> Enum.group_by(fn [_id, library_root, relative_path, _inserted_at] ->
      Path.expand(Path.join(library_root, relative_path))
    end)
    |> Enum.each(fn
      {_canonical, [_only_one]} -> :ok
      {_canonical, duplicates} -> fold_group(duplicates)
    end)
  end

  defp fold_group(duplicates) do
    [{winner_id, _, _} | losers] =
      duplicates
      |> Enum.map(fn [id, _library_root, _relative_path, inserted_at] ->
        {id, dependent_count(id), to_string(inserted_at)}
      end)
      |> Enum.sort_by(fn {id, count, inserted_at} -> {-count, inserted_at, id} end)

    Enum.each(losers, fn {loser_id, _count, _inserted_at} ->
      Enum.each(@dependents, fn dependent -> repoint(dependent, loser_id, winner_id) end)

      exec("""
      UPDATE media_files SET supersedes_media_file_id = #{lit(winner_id)}
      WHERE supersedes_media_file_id = #{lit(loser_id)}
      """)

      exec("DELETE FROM media_files WHERE id = #{lit(loser_id)}")
    end)
  end

  # Total attached rows decide; oldest row wins a tie; id makes it total.
  defp dependent_count(media_file_id) do
    Enum.reduce(@dependents, 0, fn {table, _keys}, acc ->
      %{rows: [[count]]} =
        repo().query!(
          "SELECT count(*) FROM #{table} WHERE media_file_id = #{lit(media_file_id)}",
          []
        )

      acc + count
    end)
  end

  # No unique key beyond media_file_id itself, so the winner either has a row
  # or it does not.
  defp repoint({table, []}, loser_id, winner_id) do
    exec("""
    UPDATE #{table} SET media_file_id = #{lit(winner_id)}
    WHERE media_file_id = #{lit(loser_id)}
      AND NOT EXISTS (
        SELECT 1 FROM #{table} w WHERE w.media_file_id = #{lit(winner_id)}
      )
    """)

    exec("DELETE FROM #{table} WHERE media_file_id = #{lit(loser_id)}")
  end

  defp repoint({table, keys}, loser_id, winner_id) do
    # `w.k = t.k OR (w.k IS NULL AND t.k IS NULL)` rather than
    # IS NOT DISTINCT FROM, which SQLite does not have. The update target is
    # referenced by table name, not an alias, because UPDATE ... AS is not
    # portable either.
    conditions =
      Enum.map_join(keys, " AND ", fn key ->
        "(w.#{key} = #{table}.#{key} OR (w.#{key} IS NULL AND #{table}.#{key} IS NULL))"
      end)

    exec("""
    UPDATE #{table} SET media_file_id = #{lit(winner_id)}
    WHERE media_file_id = #{lit(loser_id)}
      AND NOT EXISTS (
        SELECT 1 FROM #{table} w
        WHERE w.media_file_id = #{lit(winner_id)} AND #{conditions}
      )
    """)

    exec("DELETE FROM #{table} WHERE media_file_id = #{lit(loser_id)}")
  end

  defp exec(query), do: repo().query!(query, [])

  # SQLite binds with `?` and PostgreSQL with `$1`, so migrations here inline
  # escaped literals instead. See Mydia.Repo.Migrations.Helpers.
  defp lit(value), do: Helpers.to_db_value(value)
end
