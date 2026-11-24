defmodule Mydia.Library.SidecarCleanup do
  @moduledoc """
  Finds sidecar files left behind by earlier renames and moves them into the
  library's trash.

  A rename carries a video's sidecars with it, but files orphaned by renames
  made before that behaviour existed (an `.nfo` or `-thumb.jpg` named after a
  video that is gone) stay on disk forever. This module lists them and, on
  request, moves them to
  `<trash root>/sidecar-cleanup-<library id>-<UTC timestamp>/`
  keeping their path relative to the library root, so the operator can put
  them back by hand.

  It moves user files, so every doubt means "not an orphan". `orphan?/2` is
  true only for a regular file under the library root (and outside any trash
  directory) that:

    * is not item or season metadata (`tvshow.nfo`, `poster.*`, ...),
    * has a sidecar shape (`Sidecars.sidecar_form?/1`),
    * sits in a directory holding a video file (a symlink to one counts), and
      no non-directory, non-sidecar entry there (video, symlinked video,
      `.iso`, `.strm`, `VIDEO_TS.IFO`, ...) claims it by name, and
    * is not a tracked `Subtitle` row.

  `run/2` re-checks the same rule for every path it is given, one pass per
  directory, so a video added between the preview and the run protects its
  sidecars. Local libraries only.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.Library.{Scanner, TrashStore}
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
             container: String.t() | nil
           }}
          | {:error, error()}
  def run(%LibraryPath{} = library_path, paths) when is_list(paths) do
    with :ok <- check_available(library_path) do
      root = root_of(library_path)
      trash = trash_root(library_path)

      container =
        Path.join(TrashStore.root_for_library(library_path), container_name(library_path))

      # One listing and one stat pass per directory, not per path.
      results =
        paths
        |> Enum.filter(&is_binary/1)
        |> Enum.map(&Path.expand/1)
        |> Enum.uniq()
        |> Enum.group_by(&Path.dirname/1)
        |> Enum.flat_map(fn {dir, dir_paths} ->
          orphans = MapSet.new(dir_orphans(dir, dir_paths, root, trash))
          Enum.map(dir_paths, &move_if_orphan(&1, orphans, root, container))
        end)

      moved = for {:moved, path} <- results, do: path

      {:ok,
       %{
         moved: length(moved),
         kept: length(results) - length(moved),
         container: if(moved == [], do: nil, else: container)
       }}
    end
  end

  defp move_if_orphan(path, orphans, root, container) do
    if MapSet.member?(orphans, path) and move(path, root, container) == :ok do
      {:moved, path}
    else
      {:kept, path}
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
      path in dir_orphans(dir, [path], root_of(library_path), trash_root(library_path))
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

  # The orphans among `paths` (absolute, all in `dir`). An unlistable
  # directory has none.
  defp dir_orphans(dir, paths, root, trash) do
    case File.ls(dir) do
      {:ok, entries} -> orphans_in(dir, entries, Enum.map(paths, &Path.basename/1), root, trash)
      {:error, _} -> []
    end
  end

  # The orphans among `candidates` (basenames) of one directory listing.
  #
  # A directory is only eligible when it holds a file with a video extension
  # (a symlink to one counts), so `Movie (2019)/Subs/English.srt` is never
  # touched. Within an eligible directory any non-directory, non-sidecar entry
  # (`.iso`, `.strm`, `VIDEO_TS.IFO`, a symlinked version, even a broken link)
  # claims the sidecars named after it. Only a regular file (by lstat) can be
  # an orphan, so a symlinked sidecar is never moved.
  defp orphans_in(dir, entries, candidates, root, trash) do
    types = Map.new(entries, &{&1, types_of(Path.join(dir, &1))})

    if Enum.any?(entries, &(video?(&1) and elem(types[&1], 1) == :regular)) do
      claimants =
        for name <- entries,
            elem(types[name], 1) != :directory,
            not Sidecars.sidecar_form?(name),
            do: Path.rootname(name)

      paths =
        for name <- candidates,
            match?({:regular, _}, types[name]),
            not denied?(name),
            Sidecars.sidecar_form?(name),
            not Enum.any?(claimants, &claims?(&1, name)),
            path = Path.join(dir, name),
            inside_library?(path, root, trash),
            do: path

      tracked = tracked_subtitles(paths)
      Enum.reject(paths, &MapSet.member?(tracked, &1))
    else
      []
    end
  end

  # {lstat type, stat type}; stat follows links, :missing when it fails.
  defp types_of(path), do: {type_of(File.lstat(path)), type_of(File.stat(path))}

  defp type_of({:ok, %File.Stat{type: type}}), do: type
  defp type_of({:error, _}), do: :missing

  # Whether a file with root `claimant_root` claims `sidecar`: dot form
  # (`<root>.<anything>`) or `<root>-thumb.<ext>`, case-insensitively.
  defp claims?(claimant_root, sidecar) do
    root = String.downcase(claimant_root)
    lower = String.downcase(sidecar)

    String.starts_with?(lower, root <> ".") or Path.rootname(lower) == root <> "-thumb"
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

  # The library id keeps two libraries sharing a trash root apart.
  defp container_name(%LibraryPath{id: id}) do
    "sidecar-cleanup-#{id}-" <> (DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ"))
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
end
