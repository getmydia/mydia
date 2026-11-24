defmodule Mydia.Library.SidecarCleanup do
  @moduledoc """
  Finds sidecar files left behind by earlier renames and moves them into the
  library's trash.

  A rename carries a video's sidecars with it, but files orphaned by renames
  made before that behaviour existed (an `.nfo` or `-thumb.jpg` named after a
  video that is gone) stay on disk forever. This module lists them and, on
  request, moves them to `<trash root>/sidecar-cleanup-<UTC timestamp>/`
  keeping their path relative to the library root, so the operator can put
  them back by hand.

  It moves user files, so every doubt means "not an orphan". `orphan?/2` is
  true only for a regular file under the library root (and outside any trash
  directory) that:

    * is not item or season metadata (`tvshow.nfo`, `poster.*`, ...),
    * has a sidecar shape (`Sidecars.sidecar_form?/1`),
    * is not claimed by any video file in the same directory, and
    * is not a tracked `Subtitle` row.

  `run/2` re-checks `orphan?/2` for every path it is given, so a video added
  between the preview and the run protects its sidecars. Local libraries only.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.Library.{PathAnchor, Scanner, TrashStore}
  alias Mydia.Library.LibraryMove.Sidecars
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath
  alias Mydia.Storage
  alias Mydia.Subtitles.Subtitle

  @exact_deny ~w(tvshow.nfo movie.nfo season.nfo)
  @deny_prefixes ~w(poster. fanart. folder. banner. clearlogo. landscape.)
  @season_art ~r/^season\d+-/

  @type error :: :library_unavailable | :s3_unsupported

  @doc """
  Lists the orphaned sidecars of the library, grouped by directory.

  `destination` is the trash root they would be moved under. All paths are
  absolute.
  """
  @spec preview(LibraryPath.t()) ::
          {:ok,
           %{
             folders: [{String.t(), [String.t()]}],
             count: non_neg_integer(),
             bytes: non_neg_integer(),
             destination: String.t()
           }}
          | {:error, error()}
  def preview(%LibraryPath{} = library_path) do
    with :ok <- check_available(library_path) do
      root = root_of(library_path)
      trash = trash_root(library_path)

      folders =
        root
        |> walk(trash)
        |> Enum.map(fn {dir, entries} ->
          {dir, orphans_in(dir, entries, entries, root, trash)}
        end)
        |> Enum.reject(fn {_dir, paths} -> paths == [] end)
        |> Enum.sort_by(&elem(&1, 0))

      all = Enum.flat_map(folders, &elem(&1, 1))

      {:ok,
       %{
         folders: folders,
         count: length(all),
         bytes: Enum.reduce(all, 0, &(size_of(&1) + &2)),
         destination: TrashStore.root_for_library(library_path)
       }}
    end
  end

  @doc """
  Moves the given paths to the trash, keeping only those that are still
  orphans. Anything else counts as `kept` and is left untouched.

  `container` is the trash directory created for this run, or `nil` when
  nothing moved.
  """
  @spec run(LibraryPath.t(), [String.t()]) ::
          {:ok,
           %{
             moved: non_neg_integer(),
             kept: non_neg_integer(),
             pruned_dirs: non_neg_integer(),
             container: String.t() | nil
           }}
          | {:error, error()}
  def run(%LibraryPath{} = library_path, paths) when is_list(paths) do
    with :ok <- check_available(library_path) do
      root = root_of(library_path)
      container = Path.join(TrashStore.root_for_library(library_path), container_name())

      results =
        paths
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&Path.expand/1)
        |> Enum.uniq()
        |> Enum.map(fn path ->
          if orphan?(path, library_path) and move(path, root, container) == :ok do
            {:moved, path}
          else
            {:kept, path}
          end
        end)

      moved = for {:moved, path} <- results, do: path

      {:ok,
       %{
         moved: length(moved),
         kept: length(results) - length(moved),
         pruned_dirs: moved |> Enum.map(&prune(&1, root)) |> Enum.sum(),
         container: if(moved == [], do: nil, else: container)
       }}
    end
  end

  @doc """
  Whether `path` is an orphaned sidecar of the library path. False whenever
  there is doubt: a missing file, a non-regular file, a path outside the
  library root or inside a trash directory.
  """
  @spec orphan?(String.t(), LibraryPath.t()) :: boolean()
  def orphan?(path, %LibraryPath{path: lib_path} = library_path)
      when is_binary(path) and is_binary(lib_path) do
    if Storage.s3?(library_path) do
      false
    else
      path = Path.expand(path)
      dir = Path.dirname(path)

      case File.ls(dir) do
        {:ok, entries} ->
          path in orphans_in(
            dir,
            entries,
            [Path.basename(path)],
            root_of(library_path),
            trash_root(library_path)
          )

        {:error, _} ->
          false
      end
    end
  end

  def orphan?(_path, _library_path), do: false

  # Local-only: s3 libraries are refused, anything unreadable is unavailable.
  defp check_available(%LibraryPath{path: path} = library_path) when is_binary(path) do
    if Storage.s3?(library_path) do
      {:error, :s3_unsupported}
    else
      with {:ok, location} <- Storage.location(library_path),
           :ok <- Storage.validate(location) do
        :ok
      else
        _ -> {:error, :library_unavailable}
      end
    end
  end

  defp check_available(_), do: {:error, :library_unavailable}

  defp root_of(%LibraryPath{path: path}), do: Path.expand(path)

  defp trash_root(library_path) do
    case TrashStore.root_for_library(library_path) do
      nil -> nil
      root -> Path.expand(root)
    end
  end

  # Every directory under `root` with its entries, skipping trash directories
  # and symlinked directories. A directory that cannot be listed is skipped.
  defp walk(dir, trash) do
    case File.ls(dir) do
      {:ok, entries} ->
        subdirs =
          for entry <- entries,
              entry != TrashStore.dir_name(),
              path = Path.join(dir, entry),
              path != trash,
              match?({:ok, %File.Stat{type: :directory}}, File.lstat(path)),
              do: path

        [{dir, entries} | Enum.flat_map(subdirs, &walk(&1, trash))]

      {:error, _} ->
        []
    end
  end

  # The orphans among `candidates` (basenames) of one directory listing.
  defp orphans_in(dir, entries, candidates, root, trash) do
    videos = Enum.filter(entries, &video?/1)

    paths =
      for name <- candidates,
          name in entries,
          not denied?(name),
          Sidecars.sidecar_form?(name),
          not Enum.any?(videos, &Sidecars.sidecar_name?(name, &1)),
          path = Path.join(dir, name),
          inside_library?(path, root, trash),
          match?({:ok, %File.Stat{type: :regular}}, File.lstat(path)),
          do: path

    tracked = tracked_subtitles(paths)
    Enum.reject(paths, &MapSet.member?(tracked, &1))
  end

  defp tracked_subtitles([]), do: MapSet.new()

  defp tracked_subtitles(paths) do
    from(s in Subtitle, where: s.file_path in ^paths, select: s.file_path)
    |> Repo.all()
    |> MapSet.new()
  end

  defp inside_library?(path, root, trash) do
    case Path.relative_to(path, root) do
      ^path ->
        false

      rel ->
        TrashStore.dir_name() not in Path.split(rel) and
          not (is_binary(trash) and under?(path, trash))
    end
  end

  defp under?(path, dir), do: String.starts_with?(path, dir <> "/")

  defp video?(name),
    do: String.downcase(Path.extname(name)) in Scanner.extensions_for_library_type(:movies)

  defp denied?(name) do
    lower = String.downcase(name)

    lower in @exact_deny or String.starts_with?(lower, @deny_prefixes) or
      Regex.match?(@season_art, lower)
  end

  defp size_of(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  defp container_name do
    "sidecar-cleanup-" <> (DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ"))
  end

  defp move(path, root, container) do
    destination = Path.join(container, Path.relative_to(path, root))

    with false <- File.exists?(destination),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- rename(path, destination) do
      :ok
    else
      true ->
        Logger.warning("Sidecar cleanup target already exists", path: path, to: destination)
        {:error, :exists}

      {:error, reason} = error ->
        Logger.warning("Sidecar cleanup could not move a file",
          path: path,
          reason: inspect(reason)
        )

        error
    end
  end

  defp rename(source, destination) do
    case File.rename(source, destination) do
      {:error, :exdev} -> copy_then_remove(source, destination)
      other -> other
    end
  end

  # The source is removed only after the copy succeeded.
  defp copy_then_remove(source, destination) do
    case File.cp(source, destination) do
      :ok ->
        case File.rm(source) do
          :ok ->
            :ok

          {:error, _} = error ->
            _ = File.rm(destination)
            error
        end

      {:error, _} = error ->
        _ = File.rm(destination)
        error
    end
  end

  # Removes the directories a moved file left empty, climbing until the item
  # folder (the anchor), the library root, or a non-empty directory. The
  # anchor itself and everything above it are never removed.
  defp prune(old_path, root) do
    anchor =
      case PathAnchor.anchor_for(old_path, root).anchor_path do
        "" -> root
        rel -> Path.join(root, rel)
      end

    old_path |> Path.dirname() |> prune_up(anchor, root, 0)
  end

  defp prune_up(dir, anchor, root, count) do
    cond do
      dir in [anchor, root] or not under?(dir, anchor) ->
        count

      File.ls(dir) == {:ok, []} and File.rmdir(dir) == :ok ->
        prune_up(Path.dirname(dir), anchor, root, count + 1)

      true ->
        count
    end
  end
end
