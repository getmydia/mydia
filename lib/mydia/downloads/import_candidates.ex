defmodule Mydia.Downloads.ImportCandidates do
  @moduledoc """
  Builds the file listing that a failed import stores on its download, so the
  operator can see what the download actually contained and match files by hand.

  A candidate records why the automatic importer skipped a file. For files
  rejected on extension alone, it also carries an ffprobe verdict, which is what
  separates an obfuscated release from a fake one.
  """

  alias Mydia.Library.ContentProbe
  alias Mydia.Library.PathMapping
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.SampleDetector
  alias Mydia.Settings

  @video_extensions ~w(.mkv .mp4 .avi .mov .wmv .flv .webm .m4v .mpg .mpeg .m2ts)
  @music_extensions ~w(.mp3 .flac .wav .aac .ogg .m4a .wma .opus .ape .alac .aiff)
  @book_extensions ~w(.epub .pdf .mobi .azw .azw3 .cbr .cbz .djvu .fb2 .lit .txt .rtf)
  @adult_extensions ~w(.mkv .mp4 .avi .mov .wmv .flv .webm .m4v .jpg .jpeg .png .gif .webp .bmp .tiff)

  @probe_size_floor 10_485_760
  @probe_cap 20

  @doc "Minimum file size, in bytes, before an extension-rejected file is probed."
  @spec probe_size_floor() :: pos_integer()
  def probe_size_floor, do: @probe_size_floor

  @doc "Maximum number of files probed per download."
  @spec probe_cap() :: pos_integer()
  def probe_cap, do: @probe_cap

  @doc """
  Turns the importer's file list into persistable candidates.

  `library_type` is the resolved library's type, matching the branches in
  `MediaImport.filter_files_for_library_type/2`. `parser_opts` is the same
  keyword list the importer passes to `ReleaseParser.parse/2`, so the season and
  episode guesses here match the ones the importer would have made.
  """
  @spec build([map()], atom(), keyword()) :: [map()]
  def build(files, library_type, parser_opts) when is_list(files) do
    files
    |> build_candidates(library_type, parser_opts)
    |> add_probes()
  end

  # Candidate construction without probing, factored out so `merge/3` (the
  # live-listing path of `load/1`) can reuse it without paying for
  # `add_probes/1`'s ffprobe subprocesses on every modal open. `build/3`
  # itself is unchanged: it always probes, which is what the failure-time
  # snapshot (Task 4) wants.
  defp build_candidates(files, library_type, parser_opts) do
    Enum.map(files, &candidate(&1, library_type, parser_opts))
  end

  defp candidate(file, library_type, parser_opts) do
    parsed = ReleaseParser.parse(file.name, parser_opts)

    %{
      "path" => file.path,
      "name" => file.name,
      "size" => file.size,
      "skip_reason" => skip_reason(file, library_type),
      "parsed_season" => parsed && parsed.season,
      "parsed_episode" => parsed && first_episode(parsed)
    }
  end

  defp first_episode(%{episodes: episodes}) when is_list(episodes), do: List.first(episodes)
  defp first_episode(_parsed), do: nil

  # Mirrors the importer's two filters in the same order, so the reason shown to
  # the operator is the reason the file was actually dropped.
  defp skip_reason(file, library_type) do
    cond do
      not importable?(file, library_type) ->
        "not_video_extension"

      SampleDetector.skip_detection?(file.path) ->
        nil

      true ->
        detection = SampleDetector.detect(file.path)

        if SampleDetector.excluded?(detection) do
          SampleDetector.exclusion_reason(detection)
        end
    end
  end

  @doc """
  True when `file` has an extension the given library type accepts.

  This module owns the extension vocabulary. `MediaImport` delegates its own
  filtering here so the skip reason shown to the operator can never disagree
  with the filter that actually dropped the file.
  """
  @spec importable?(map(), atom()) :: boolean()
  def importable?(file, library_type) do
    ext = file.name |> Path.extname() |> String.downcase()

    case library_type do
      type when type in [:movies, :series, :mixed] -> ext in @video_extensions
      :music -> ext in @music_extensions
      :books -> ext in @book_extensions
      :adult -> ext in @adult_extensions
      _unknown -> true
    end
  end

  # Only files rejected purely on extension are worth probing: everything else
  # either imported fine or was correctly identified as a sample.
  defp add_probes(candidates) do
    probable =
      candidates
      |> Enum.filter(&probe?/1)
      |> Enum.take(@probe_cap)
      |> MapSet.new(& &1["path"])

    Enum.map(candidates, fn candidate ->
      if MapSet.member?(probable, candidate["path"]) do
        Map.put(candidate, "probe", ContentProbe.probe(candidate["path"]))
      else
        candidate
      end
    end)
  end

  defp probe?(candidate) do
    candidate["skip_reason"] == "not_video_extension" and
      candidate["size"] >= @probe_size_floor
  end

  @doc """
  Loads the candidate listing to show the operator.

  Prefers a live re-listing of the download folder, since the operator may
  have fixed a mount or permission since the failure, but only when the
  recorded `metadata["save_path"]` is specific to this download. A
  `save_path` that resolves to the download client's own shared download
  root is never walked recursively (see `shared_download_root?/2`):
  clients that put a download's files directly inside their shared output
  folder would otherwise have every *other* download sharing that folder
  enumerated and offered up for import here.

  This fails closed: a live listing only happens when the download's
  client resolves to a *known* `download_directory` that is provably
  different from `save_path`. A client that no longer resolves (renamed or
  deleted — plausible in a self-hosted deployment reconfigured by env
  vars, and a failed download can sit for weeks before anyone opens this
  modal) means there is no way to prove `save_path` is not that client's
  shared root, so it is treated the same as if it were.

  Falls back to the snapshot captured at failure time whenever a live
  listing isn't possible or safe: no `save_path`, an unresolvable client,
  a `save_path` that is the shared root, a folder that no longer exists,
  or one that comes back empty. In the fallback case each recorded path is
  individually re-stat'd rather than the directory being walked, so files
  that vanished are still caught without ever enumerating unrelated
  downloads.

  Every returned candidate carries `"missing"`, true when the path is no
  longer on disk.
  """
  @spec load(Mydia.Downloads.Download.t()) ::
          {:ok, :live | :snapshot, [map()]} | {:error, :unavailable}
  def load(download) do
    metadata = download.metadata || %{}
    snapshot = candidate_snapshot(metadata)

    case live_listing(download, metadata) do
      {:ok, files} when files != [] ->
        {:ok, :live, merge(files, snapshot, download)}

      _not_live ->
        if snapshot == [] do
          {:error, :unavailable}
        else
          {:ok, :snapshot, Enum.map(snapshot, &mark_missing/1)}
        end
    end
  end

  # Prefers the failure-time `"import_candidates"` snapshot (written by
  # `MediaImport.snapshot_candidates_on_failure/4` on every import failure).
  # Downloads flagged `unresolved_files` before that snapshot existed only
  # carry `metadata["unresolved_files"]` (written by
  # `MediaImport.flag_unresolved_files/2`), and in a self-hosted deployment
  # those rows persist indefinitely until an operator resolves them. Falling
  # back to normalizing that list keeps the modal usable for them instead of
  # reporting "unavailable" and stranding an operator who relied on the
  # inline picker this modal replaces.
  defp candidate_snapshot(metadata) do
    case Map.get(metadata, "import_candidates") do
      candidates when is_list(candidates) and candidates != [] ->
        candidates

      _no_snapshot ->
        metadata
        |> Map.get("unresolved_files")
        |> List.wrap()
        |> Enum.map(&normalize_unresolved_file/1)
    end
  end

  # `flag_unresolved_files/2` writes "path", "name", "size", "parsed_season",
  # "parsed_episode", and "assigned_episode_id" — no "skip_reason" or
  # "probe", since those only exist on the newer import-candidates path.
  # Missing keys degrade gracefully: the modal template only renders a probe
  # or skip-reason line when the key is present/truthy.
  defp normalize_unresolved_file(file) do
    path = file["path"]

    %{
      "path" => path,
      "name" => file["name"] || basename(path),
      "size" => file["size"],
      "skip_reason" => nil,
      "parsed_season" => file["parsed_season"],
      "parsed_episode" => file["parsed_episode"]
    }
  end

  defp basename(path) when is_binary(path) and path != "", do: Path.basename(path)
  defp basename(_path), do: nil

  defp live_listing(download, metadata) do
    case listable_save_path(metadata, download) do
      nil ->
        {:error, :no_path}

      path ->
        if File.dir?(path) do
          {:ok, list_recursive(path)}
        else
          {:error, :not_a_directory}
        end
    end
  end

  # Only a `save_path` explicitly present on the download's own metadata is
  # eligible for a live re-listing, and only when it can be *proven* not to
  # be the download client's shared root. There is deliberately no
  # fallback to `Path.dirname/1` of a snapshot path here: in production,
  # downloads sometimes sit directly inside the client's shared download
  # root, and `Path.dirname/1` of a file in that root IS the root, so
  # recursively listing it would surface every unrelated torrent's files as
  # if they belonged to this download.
  defp listable_save_path(metadata, download) do
    case Map.get(metadata, "save_path") do
      path when is_binary(path) and path != "" ->
        safe_to_list?(path, download)

      _other ->
        nil
    end
  end

  # Fails closed. This only returns `save_path` (making it eligible for a
  # live listing) when the download's client resolves to a known,
  # non-blank `download_directory` that `shared_download_root?/2` can
  # positively rule out as the same directory. An unresolvable client, or
  # one with no `download_directory` configured, means there is nothing to
  # compare `save_path` against — "unknown" must mean "don't enumerate",
  # not "assume it's safe".
  defp safe_to_list?(save_path, download) do
    case client_download_directory(download) do
      root when is_binary(root) and root != "" ->
        if shared_download_root?(save_path, root), do: nil, else: save_path

      _unresolved ->
        nil
    end
  end

  @doc """
  True when `save_path` and `download_root` name the same directory on
  disk, tolerant of any configured path-mapping rewrite applying to either
  side.

  This is the single source of truth for "is this path actually a download
  client's shared download root, not a folder specific to one download."
  `Mydia.Jobs.MediaImport` delegates to this before its own save_path
  fallback, and `load/1` delegates to it before offering a live
  re-listing, so the two can never silently disagree about what is safe to
  recursively enumerate.

  Returns `false` (not proven shared) whenever either argument is missing
  or blank — callers that need "unknown" to mean "assume shared" must
  apply that policy themselves, since what counts as an acceptable
  assumption differs: the importer already refuses to run at all when it
  cannot resolve a client, so it only reaches this check with a resolved
  one; `load/1` has no such upstream gate and fails closed itself before
  calling this.
  """
  @spec shared_download_root?(String.t() | nil, String.t() | nil) :: boolean()
  def shared_download_root?(save_path, download_root)

  def shared_download_root?(save_path, download_root)
      when is_binary(save_path) and save_path != "" and
             is_binary(download_root) and download_root != "" do
    same_dir?(save_path, download_root) or
      same_dir?(PathMapping.rewrite(save_path), PathMapping.rewrite(download_root))
  end

  def shared_download_root?(_save_path, _download_root), do: false

  defp client_download_directory(%{download_client: name})
       when is_binary(name) and name != "" do
    Settings.list_download_client_configs()
    |> Enum.find(&(&1.name == name))
    |> case do
      nil -> nil
      config -> Map.get(config, :download_directory)
    end
  end

  defp client_download_directory(_download), do: nil

  defp same_dir?(a, b) when is_binary(a) and a != "" and is_binary(b) and b != "",
    do: Path.expand(a) == Path.expand(b)

  defp same_dir?(_a, _b), do: false

  defp list_recursive(dir) do
    dir
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: false)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(fn path ->
      %{path: path, name: Path.basename(path), size: File.stat!(path).size}
    end)
  end

  # Re-derive skip reasons from the live listing, but keep any probe verdict
  # already computed for the same path so the modal does not spawn a fresh
  # ffprobe subprocess (up to `probe_cap/0` of them, each with its own
  # timeout) on every open. Calls `build_candidates/3` rather than
  # `build/3` deliberately: the latter always probes, which is correct for
  # the failure-time snapshot but far too slow for a synchronous
  # modal-open re-listing whose accurate verdicts are already sitting in
  # the snapshot to restore.
  defp merge(files, snapshot, download) do
    probes =
      snapshot
      |> Enum.filter(&Map.has_key?(&1, "probe"))
      |> Map.new(&{&1["path"], &1["probe"]})

    files
    |> build_candidates(library_type_for(download), [])
    |> Enum.map(fn candidate ->
      candidate
      |> maybe_restore_probe(probes)
      |> Map.put("missing", false)
    end)
  end

  defp maybe_restore_probe(candidate, probes) do
    case Map.fetch(probes, candidate["path"]) do
      {:ok, probe} -> Map.put(candidate, "probe", probe)
      :error -> candidate
    end
  end

  # This is a display-only guess (the actual library type used at import
  # time comes from the resolved library path, not the media item), so a
  # mismatch is cosmetic. `media_item` may be an unloaded association when
  # the caller didn't preload it: Elixir's map pattern matching falls
  # through to the next clause rather than raising when a key is absent, so
  # `%Ecto.Association.NotLoaded{}` safely falls to the :series guess below.
  defp library_type_for(%{media_item: %{type: "movie"}}), do: :movies
  defp library_type_for(_download), do: :series

  defp mark_missing(candidate) do
    Map.put(candidate, "missing", not File.regular?(candidate["path"] || ""))
  end
end
