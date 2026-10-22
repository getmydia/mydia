defmodule Mydia.Jobs.MediaImport.Placement do
  @moduledoc false

  require Logger
  alias Mydia.Downloads.{ClientRemoval, ImportCandidates}
  alias Mydia.Library
  alias Mydia.Library.{Dirs, FileOrganizer, MediaFile}
  alias Mydia.Settings
  alias Mydia.Storage
  alias Mydia.Upgrades
  alias Mydia.Jobs.MediaImport.{Args, Discovery, Paths, Records}

  # How many `name.N.ext` variants to try when a destination filename is taken
  # by different content. Deliberately small: more than a handful of distinct
  # files claiming one episode's filename means the parse is wrong, and
  # numbering on forever is what let one bad import fill a disk.
  @max_conflict_suffixes 10

  # Subfolders a release ships with; any other one in a job folder is another job.
  @job_folder_clutter_dirs ~w(sample samples subs subtitles proof proofs extras featurettes screens screenshots covers)

  @doc false
  def import_file_to_destination(file, episode, dest_dir, download, library_path, args) do
    # Ensure destination directory exists. Use the non-raising variant so a
    # permission/filesystem error becomes a handled {:error, ...} that flows
    # through handle_import_failure (persisting import_last_error and surfacing
    # in the UI) instead of crashing the Oban job silently.
    case ensure_destination_dir(dest_dir) do
      :ok ->
        import_file_to_existing_dir(file, episode, dest_dir, download, library_path, args)

      {:error, reason} ->
        Logger.error("Failed to create destination directory",
          dest_dir: dest_dir,
          reason: inspect(reason)
        )

        {:error, {:destination_not_accessible, dest_dir}}
    end
  end

  defp import_file_to_existing_dir(file, episode, dest_dir, download, library_path, args) do
    # Generate filename (optionally renamed with TRaSH format)
    final_filename = Paths.generate_filename(download, episode, file.name, args.rename_files)
    dest_path = Path.join(dest_dir, final_filename)

    # Check if file already exists
    case destination_exists?(dest_path) do
      {:error, error} ->
        Logger.error("Could not check the destination",
          dest: dest_path,
          reason: inspect(error)
        )

        {:error, error}

      true ->
        import_into_existing_destination(file, dest_path, episode, download, library_path, args)

      false ->
        import_into_free_destination(file, dest_path, episode, download, library_path, args)
    end
  end

  defp import_into_existing_destination(file, dest_path, episode, download, library_path, args) do
    Logger.warning("File already exists at destination",
      source: file.path,
      dest: dest_path
    )

    # Try to find existing media_file record
    case Library.get_media_file_by_path(dest_path) do
      nil ->
        # File exists but not in DB - this is a conflict
        handle_file_conflict(file, dest_path, episode, download, library_path, args)

      %{id: id} = existing_file ->
        case download.metadata do
          %{"upgrade_target_media_file_id" => ^id} ->
            import_onto_upgrade_target(
              file,
              dest_path,
              existing_file,
              episode,
              download,
              library_path,
              args
            )

          _ ->
            reuse_existing_file(dest_path, existing_file)
        end
    end
  end

  defp reuse_existing_file(dest_path, existing_file) do
    Logger.info("Reusing existing media file", path: dest_path)
    {:ok, existing_file}
  end

  # An upgrade whose destination is the very file it targets is one of two
  # things, told apart by size as handle_file_conflict/6 does. The same size is
  # the release already on disk: blacklist it, or the sweep grabs it every
  # night, since no new file means finalize never rejects it. A different size
  # is another release that renaming mapped to the same name, a real
  # candidate: place it beside the target so finalize compares the two.
  defp import_onto_upgrade_target(file, dest_path, target, episode, download, library_path, args) do
    case file_size(dest_path) do
      {:ok, size} when size == file.size ->
        Upgrades.blacklist_redundant_upgrade(download, target)
        reuse_existing_file(dest_path, target)

      {:ok, _other} ->
        place_conflicting_file(file, dest_path, episode, download, library_path, args)

      {:error, error} ->
        Logger.error("Could not read the size of the existing destination",
          dest: dest_path,
          reason: inspect(error)
        )

        {:error, error}
    end
  end

  defp import_into_free_destination(file, dest_path, episode, download, library_path, args) do
    # Copy or move file. `:expected_size` closes the window between the
    # existence check and the placement itself: a concurrent import that
    # already wrote the right bytes is adopted rather than
    # hardlinked-onto-EEXIST and re-copied.
    case copy_or_move_file(file.path, dest_path, args, expected_size: file.size) do
      :ok ->
        Records.create_media_file_record(dest_path, file.size, episode, download, library_path)

      {:error, reason} ->
        Logger.error("Failed to copy/move file",
          source: file.path,
          dest: dest_path,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp handle_file_conflict(file, dest_path, episode, download, library_path, args) do
    case file_size(dest_path) do
      {:ok, size} when size == file.size ->
        # Files are likely identical - create DB record
        Logger.info("File sizes match, creating DB record", path: dest_path)
        Records.create_media_file_record(dest_path, file.size, episode, download, library_path)

      {:ok, _other} ->
        place_conflicting_file(file, dest_path, episode, download, library_path, args)

      {:error, error} ->
        # A storage error says nothing about the content; never guess "different".
        Logger.error("Could not read the size of the existing destination",
          dest: dest_path,
          reason: inspect(error)
        )

        {:error, error}
    end
  end

  defp place_conflicting_file(file, dest_path, episode, download, library_path, args) do
    case resolve_conflict_path(dest_path, file.size) do
      {:existing, path} ->
        # A previous attempt already placed this exact file under a conflict
        # suffix. Adopt it instead of copying the bytes again.
        Logger.info("Reusing conflict copy placed by an earlier attempt", path: path)
        Records.create_media_file_record(path, file.size, episode, download, library_path)

      {:new, path} ->
        Logger.info("File conflict, using unique name", new_path: path)

        case copy_or_move_file(file.path, path, args, expected_size: file.size) do
          :ok ->
            Records.create_media_file_record(path, file.size, episode, download, library_path)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Could not find a free conflict filename",
          dest: dest_path,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Picks the destination for a file whose ideal name is already taken by
  # different content.
  #
  # This used to append `DateTime.to_unix()`, which made every retry of a
  # failed import mint a brand-new filename and re-copy the whole file. With
  # `max_attempts: 1000` that is how a handful of misplaced episodes became
  # ~980 GiB of duplicates in production. Numbering deterministically means a
  # retry lands on the same candidate, sees the file it wrote last time, and
  # adopts it instead of copying again.
  #
  # Returns `{:existing, path}` when a suffixed sibling already holds content
  # of the expected size, `{:new, path}` for the lowest free suffix, or
  # `{:error, {:too_many_conflicts, dest}}` once the suffix budget is spent.
  defp resolve_conflict_path(dest_path, size) do
    ext = Path.extname(dest_path)
    base = Path.basename(dest_path, ext)
    dir = Path.dirname(dest_path)

    Enum.reduce_while(1..@max_conflict_suffixes, nil, fn n, _acc ->
      candidate = Path.join(dir, "#{base}.#{n}#{ext}")

      case destination_exists?(candidate) do
        {:error, error} -> {:halt, {:error, error}}
        false -> {:halt, {:new, candidate}}
        true -> conflict_candidate(candidate, size)
      end
    end)
    |> case do
      nil -> {:error, {:too_many_conflicts, dest_path}}
      result -> result
    end
  end

  defp conflict_candidate(candidate, size) do
    case file_size(candidate) do
      {:ok, ^size} -> {:halt, {:existing, candidate}}
      {:ok, _other} -> {:cont, nil}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  # An S3 library has no directories to create, and its existence checks ask
  # the bucket.
  defp ensure_destination_dir("s3://" <> _), do: :ok
  defp ensure_destination_dir(dir), do: File.mkdir_p(dir)

  # Tri-state: true, false, or {:error, error}. Only a not-found answer from
  # the bucket means the name is free; an outage must never read as "free".
  defp destination_exists?("s3://" <> _ = path) do
    with {:ok, source} <- Storage.at(path) do
      case Storage.stat(source) do
        {:ok, _} -> true
        {:error, %Storage.Error{kind: :not_found}} -> false
        {:error, error} -> {:error, error}
      end
    end
  end

  defp destination_exists?(path), do: File.exists?(path)

  # `{:ok, size | nil}` or `{:error, error}`. On S3 any storage error is
  # surfaced, since "unknown size" must not read as "different content".
  defp file_size("s3://" <> _ = path) do
    with {:ok, source} <- Storage.at(path),
         {:ok, %{size: size}} <- Storage.stat(source) do
      {:ok, size}
    end
  end

  # File.stat/1 rather than File.stat!/1: the caller has already checked the
  # path exists, but a file that vanishes in between should not crash the job.
  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> {:ok, size}
      {:error, _} -> {:ok, nil}
    end
  end

  defp copy_or_move_file(source, dest, %Args{} = args, opts) do
    # `:expected_size` lets FileOrganizer treat an already-correct destination
    # as placed instead of hardlinking onto EEXIST and falling through to a
    # full copy — the difference between a retry being free and a retry
    # duplicating the file.
    place_opts = Keyword.merge(placement_opts(args), opts)

    case FileOrganizer.place_file(source, dest, place_opts) do
      {:ok, action} ->
        Logger.info("Placed file", from: source, to: dest, action: action)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Placement never removes the source: hardlink when possible, otherwise copy.
  # Sources a client no longer needs go later, via `remove_consumed_sources/3`.
  defp placement_opts(%Args{} = args),
    do: [use_hardlinks: args.use_hardlinks, fallback: :copy]

  # A source counts as placed only when its file got a media_file record
  # (reusing an existing one on a retry included). The record's size goes
  # along, so removal can tell the source's own copy from a different file
  # that happened to own the destination name.
  @doc false
  def placed_sources(paths, results) do
    for {path, {:ok, %{size: size}}} <- Enum.zip(paths, results), do: {path, size}
  end

  # Hardlinks are verified after the fact by inode rather than threaded back out
  # of FileOrganizer: a reused record, an adopted `:exists` destination and a
  # fresh placement all answer the same question this way.
  @doc false
  def placement_summary(paths, results, library_path, %Args{use_hardlinks: true}) do
    pairs =
      for {source, {:ok, %MediaFile{relative_path: rel}}} <- Enum.zip(paths, results),
          is_binary(rel),
          dest = Path.join(library_path.path, rel),
          not Storage.s3?(source) and not Storage.s3?(dest),
          same_size?(source, dest),
          do: {source, dest}

    case {pairs, Enum.find(pairs, fn {s, d} -> not same_inode?(s, d) end)} do
      {[], _} ->
        nil

      {_, nil} ->
        %{"method" => "hardlink"}

      {_, {s, d}} ->
        %{
          "method" => "copy",
          "reason" => Atom.to_string(FileOrganizer.hardlink_blocker(s, d))
        }
    end
  end

  def placement_summary(_paths, _results, _library_path, %Args{}), do: nil

  @doc false
  def put_placement(metadata, nil), do: metadata
  def put_placement(metadata, placement), do: Map.put(metadata, "import_placement", placement)

  # Adds the merged metadata to a download update only when there is a summary.
  @doc false
  def attach_placement(attrs, _metadata, nil), do: attrs

  def attach_placement(attrs, metadata, placement),
    do: Map.put(attrs, :metadata, put_placement(metadata || %{}, placement))

  # The job folder goes only once the import is complete.
  @doc false
  def cleanup_sources(placed, args, download, library_type, complete?) do
    remove_consumed_sources(placed, args, download)
    if complete?, do: remove_job_folder(placed, args, download, library_type)
    :ok
  end

  # A reused record can point at a different release's file; its bytes are not
  # this source's, so there is nothing to explain.
  defp same_size?(a, b) do
    with {:ok, %File.Stat{size: size}} <- File.stat(a),
         {:ok, %File.Stat{size: ^size}} <- File.stat(b) do
      true
    else
      _ -> false
    end
  end

  defp same_inode?(a, b) do
    with {:ok, %File.Stat{inode: i, major_device: d}} <- File.stat(a),
         {:ok, %File.Stat{inode: ^i, major_device: ^d}} <- File.stat(b) do
      true
    else
      _ -> false
    end
  end

  # Once the import is recorded, a client that never seeds has no use for the
  # placed sources. A source whose size differs from its library record was
  # matched to someone else's file and stays. A missing file is fine (the
  # client may have cleaned up); any other failure is logged and never fails
  # the job.
  @doc false
  def remove_consumed_sources(sources, %Args{move_source: true}, download) do
    Enum.each(sources, fn {path, size} ->
      result =
        case File.stat(path) do
          {:ok, %File.Stat{size: ^size}} -> File.rm(path)
          {:ok, _} -> {:error, :differs_from_library_file}
          {:error, _} = error -> error
        end

      case result do
        result when result in [:ok, {:error, :enoent}] ->
          :ok

        {:error, reason} ->
          Logger.warning("Kept consumed source",
            path: path,
            reason: inspect(reason),
            download_id: download.id
          )
      end
    end)
  end

  def remove_consumed_sources(_paths, %Args{}, _download), do: :ok

  # A SABnzbd or NZBGet job folder holds only that job's files, so once its
  # media is placed and removed the leftovers (.nfo, samples) are clutter.
  # Every guard fails toward keeping the folder; this never raises and never
  # fails the job.
  @doc false
  def remove_job_folder(sources, %Args{} = args, download, library_type) do
    if job_folder_candidate?(sources, args, download) do
      # Sources are rewritten through path mappings, so the folder must be too.
      save_path = Discovery.mapped_path(args.save_path, download.id)

      with :ok <- check_folder_exists(save_path),
           :ok <- check_sources_inside(sources, save_path),
           :ok <- check_not_client_root(save_path, download),
           :ok <- check_no_library_overlap(save_path),
           :ok <- check_no_unknown_subfolder(sources, save_path),
           {:ok, files} <- list_job_files(save_path),
           :ok <- check_no_media_left(files, library_type) do
        rm_job_folder(save_path, download)
      else
        :gone ->
          :ok

        {:keep, reason} ->
          Logger.info("Kept job folder",
            path: save_path,
            reason: reason,
            download_id: download.id
          )

          :ok
      end
    else
      :ok
    end
  end

  defp job_folder_candidate?(sources, %Args{move_source: true, save_path: save_path}, download)
       when is_binary(save_path) and sources != [] do
    Path.type(save_path) == :absolute and ClientRemoval.job_folder_client?(download)
  end

  defp job_folder_candidate?(_sources, _args, _download), do: false

  # A folder that is already gone needs nothing, and is not worth a log line.
  defp check_folder_exists(save_path), do: if(File.dir?(save_path), do: :ok, else: :gone)

  defp check_sources_inside(sources, save_path) do
    if Enum.all?(sources, fn {path, _size} -> Dirs.inside?(path, save_path) end),
      do: :ok,
      else: {:keep, :sources_outside}
  end

  # The client's configured root holds every job, never just this one.
  defp check_not_client_root(save_path, download) do
    if ImportCandidates.shared_download_root?(
         save_path,
         ImportCandidates.client_download_directory(download)
       ),
       do: {:keep, :client_root},
       else: :ok
  end

  # A folder that is, or contains, a library path must never be deleted.
  defp check_no_library_overlap(save_path) do
    overlaps? =
      Settings.list_library_paths()
      |> Enum.map(& &1.path)
      |> Enum.filter(&(is_binary(&1) and not String.starts_with?(&1, "s3://")))
      |> Enum.any?(
        &(Dirs.normalize(&1) == Dirs.normalize(save_path) or Dirs.inside?(&1, save_path))
      )

    if overlaps?, do: {:keep, :library_overlap}, else: :ok
  end

  # `download_directory` is optional, so a shared download root can slip past
  # the client-root guard. Its other jobs show up as subfolders that hold none
  # of this import's sources and are not the usual release clutter.
  defp check_no_unknown_subfolder(sources, save_path) do
    case File.ls(save_path) do
      {:ok, names} ->
        unknown? =
          names
          |> Enum.map(&Path.join(save_path, &1))
          |> Enum.filter(&File.dir?/1)
          |> Enum.any?(&unknown_subfolder?(&1, sources))

        if unknown?, do: {:keep, :unknown_subfolder}, else: :ok

      {:error, reason} ->
        {:keep, {:list_failed, reason}}
    end
  end

  defp unknown_subfolder?(dir, sources) do
    String.downcase(Path.basename(dir)) not in @job_folder_clutter_dirs and
      not Enum.any?(sources, fn {path, _size} -> Dirs.inside?(path, dir) end)
  end

  defp list_job_files(save_path) do
    case Discovery.list_files_in_path(save_path) do
      {:ok, files} -> {:ok, files}
      {:error, reason} -> {:keep, {:list_failed, reason}}
    end
  end

  # Another job's media in the folder (a shared or misreported save path)
  # shows up as importable files; leave the folder alone then.
  defp check_no_media_left(files, library_type) do
    left =
      files
      |> Discovery.filter_files_for_library_type(library_type)
      |> Discovery.filter_extras_and_samples()

    if left == [], do: :ok, else: {:keep, :media_left}
  end

  defp rm_job_folder(save_path, download) do
    case File.rm_rf(save_path) do
      {:ok, _} ->
        :ok

      {:error, reason, file} ->
        Logger.warning("Kept job folder",
          path: save_path,
          file: file,
          reason: inspect(reason),
          download_id: download.id
        )
    end
  end
end
