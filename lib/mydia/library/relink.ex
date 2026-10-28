defmodule Mydia.Library.Relink do
  @moduledoc """
  Recognises a file renamed or moved outside Mydia and repoints its existing
  `media_files` row at the new path.

  Without this a rename shows up as two unrelated events, a path that vanished
  and a path that appeared, and the new path becomes a fresh row while the old
  one is trashed as missing. The fresh row has lost everything keyed to the old
  row's id: subtitles, detected segments, track settings and episode links.

  A gone row and a found file pair when their sizes are equal and they share
  either a parent directory (a rename) or a file name (a move). Only
  one-to-one matches pair; anything ambiguous is left for the caller's
  existing handling.

  Two kinds of match are refused outright:

    * A row whose bytes sit in the trash directory (`trashed_path` recorded).
      Relinking clears that key, which would orphan the trashed copy where
      nothing tracks or purges it.
    * A pair whose file names both parse to an episode and name different
      episodes. Renaming `S01E01.mkv` to `S01E02.mkv` is how an operator
      fixes a misnumbered file, so the new name has to be matched afresh
      rather than keep the old episode link.
  """

  require Logger

  alias Mydia.Library.{MediaFile, MediaFiles, ReleaseParser, Trash}
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  @type file_info :: %{
          required(:path) => String.t(),
          required(:size) => non_neg_integer(),
          optional(atom()) => term()
        }

  @doc """
  Pairs vanished rows with newly found files.

  Pure. `gone` rows need `:library_path` preloaded. Returns
  `{pairs, unpaired_gone, unpaired_found}`.
  """
  @spec pair([MediaFile.t()], [file_info()]) ::
          {[{MediaFile.t(), file_info()}], [MediaFile.t()], [file_info()]}
  def pair(gone, found) do
    edges =
      for g <- gone,
          g_path = gone_path(g),
          g_path != nil,
          is_integer(g.size),
          not holds_trash_copy?(g),
          f <- found,
          f.size == g.size,
          same_dir_or_name?(g_path, f.path),
          same_episode?(g_path, f.path),
          do: {g, f}

    gone_degree = Enum.frequencies_by(edges, fn {g, _} -> g.id end)
    found_degree = Enum.frequencies_by(edges, fn {_, f} -> f.path end)

    pairs =
      Enum.filter(edges, fn {g, f} ->
        gone_degree[g.id] == 1 and found_degree[f.path] == 1
      end)

    paired_ids = MapSet.new(pairs, fn {g, _} -> g.id end)
    paired_paths = MapSet.new(pairs, fn {_, f} -> f.path end)

    {pairs, Enum.reject(gone, &MapSet.member?(paired_ids, &1.id)),
     Enum.reject(found, &MapSet.member?(paired_paths, &1.path))}
  end

  @doc """
  Repoints `row` at the file described by `file_info`, which lives under
  `library_path`. Clears any trash state, so a row trashed as missing comes
  back active. Returns `{:error, changeset}` if another active row already
  occupies the target path.

  The update runs in a savepoint: inside a transaction, PostgreSQL aborts the
  whole transaction on a constraint violation, and the remaining relinks in a
  batch (`Relink.Scan`) must still run.
  """
  @spec relink(MediaFile.t(), file_info(), LibraryPath.t()) ::
          {:ok, MediaFile.t()} | {:error, term()}
  def relink(%MediaFile{} = row, %{path: path, size: size}, %LibraryPath{} = library_path) do
    relative_path = Path.relative_to(path, library_path.path)

    row
    |> Ecto.Changeset.change(
      library_path_id: library_path.id,
      relative_path: relative_path,
      path: path,
      size: size,
      verified_at: DateTime.utc_now() |> DateTime.truncate(:second),
      trashed_at: nil,
      trashed_reason: nil,
      metadata: Trash.drop_trash_state(row.metadata)
    )
    |> guard_unique_path()
    |> Repo.update(mode: :savepoint)
  end

  @doc """
  Relinks every pair, resolving each file's library from `library_paths`.

  Returns `{relinked, failed}`; failures are logged and left to the caller's
  fallback (treating the file as new).
  """
  @spec relink_all([{MediaFile.t(), file_info()}], [LibraryPath.t()]) ::
          {[{MediaFile.t(), file_info()}], [{MediaFile.t(), file_info()}]}
  def relink_all(pairs, library_paths) do
    Enum.split_with(pairs, fn {row, info} ->
      with {lp_id, _rel} when not is_nil(lp_id) <-
             MediaFiles.calculate_relative_path(info.path, library_paths),
           %{} = lp <- Enum.find(library_paths, &(&1.id == lp_id)),
           {:ok, _} <- relink(row, info, lp) do
        Logger.info("Relinked a file renamed or moved outside Mydia",
          media_file_id: row.id,
          from: gone_path(row),
          to: info.path
        )

        true
      else
        other ->
          Logger.warning("Could not relink a renamed or moved file; treating it as new",
            media_file_id: row.id,
            from: gone_path(row),
            to: info.path,
            reason: inspect(other)
          )

          false
      end
    end)
  end

  # Postgres names the partial unique index; SQLite derives the conventional
  # name from the columns. Declare both, as MediaFile does.
  defp guard_unique_path(changeset) do
    changeset
    |> Ecto.Changeset.unique_constraint([:library_path_id, :relative_path],
      name: :media_files_active_library_path_relative_path_index,
      error_key: :relative_path,
      message: "already tracked at this library path"
    )
    |> Ecto.Changeset.unique_constraint([:library_path_id, :relative_path],
      name: :media_files_library_path_id_relative_path_index,
      error_key: :relative_path,
      message: "already tracked at this library path"
    )
  end

  # The storage path is what a scan reports for a found file: the absolute
  # path for a local library, `s3://...` for an S3 one. An unloaded library
  # falls back to the relative path.
  defp gone_path(%MediaFile{} = g), do: MediaFile.storage_path(g) || g.relative_path

  defp same_dir_or_name?(a, b),
    do: Path.dirname(a) == Path.dirname(b) or Path.basename(a) == Path.basename(b)

  @doc """
  True when `row` records a copy of its bytes in the trash directory. Such a
  row must never be relinked: relinking drops `trashed_path`, and the copy
  would sit under `.mydia-trash/` with nothing left to restore or purge it.
  """
  @spec holds_trash_copy?(MediaFile.t()) :: boolean()
  def holds_trash_copy?(%MediaFile{metadata: %FileMetadata{extra: %{"trashed_path" => path}}})
      when is_binary(path) and path != "",
      do: true

  def holds_trash_copy?(%MediaFile{}), do: false

  # Only refuses when both names parse to an episode and the episodes differ.
  # A name with no episode marker on either side says nothing either way.
  defp same_episode?(a, b) do
    case {episode_identity(a), episode_identity(b)} do
      {{_, _} = x, {_, _} = y} -> x == y
      _ -> true
    end
  end

  defp episode_identity(path) do
    case ReleaseParser.parse(Path.basename(path)) do
      %{episodes: [_ | _] = episodes, season: season} -> {season, Enum.sort(episodes)}
      _ -> nil
    end
  end
end
