defmodule Mydia.Library do
  @moduledoc """
  The Library context handles media files and library management.
  """

  import Ecto.Query, warn: false
  import Mydia.DB
  import Mydia.QueryHelpers
  alias Mydia.Repo
  alias Mydia.Library.{MediaFile, FileAnalyzer, PhashGenerator, Text, TrashStore}
  alias Mydia.Library.ReleaseParser, as: FileParser
  alias Mydia.Library.Structs.FileMetadata

  require Logger

  @doc """
  Returns the total storage used by all media files in bytes.
  """
  @spec total_storage_bytes() :: non_neg_integer()
  def total_storage_bytes do
    MediaFile
    |> where([f], is_nil(f.trashed_at))
    |> select([f], type(sum(f.size), :integer))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  Returns the list of media files.

  ## Options
    - `:media_item_id` - Filter by media item
    - `:episode_id` - Filter by episode
    - `:library_path_id` - Filter by library path ID
    - `:library_path_type` - Filter by library path type (e.g., :adult, :music, :books)
    - `:preload` - List of associations to preload
  """
  @spec list_media_files(keyword()) :: [MediaFile.t()]
  def list_media_files(opts \\ []) do
    MediaFile
    |> apply_media_file_filters(opts)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Returns a list of unique media item IDs that have files in the given library path.
  """
  @spec list_media_ids_in_library_path(%{id: binary()}) :: [binary()]
  def list_media_ids_in_library_path(%{id: library_path_id}) do
    MediaFile
    |> where([mf], mf.library_path_id == ^library_path_id)
    |> where([mf], not is_nil(mf.media_item_id))
    |> where([mf], is_nil(mf.trashed_at))
    |> select([mf], mf.media_item_id)
    |> distinct(true)
    |> Repo.all()
  end

  @doc """
  Gets a single media file.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the media file does not exist.
  """
  @spec get_media_file!(binary(), keyword()) :: MediaFile.t()
  def get_media_file!(id, opts \\ []) do
    MediaFile
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a single media file, returning nil if not found.

  ## Options
    - `:preload` - List of associations to preload

  Returns the media file or nil if not found.
  """
  @spec get_media_file(binary(), keyword()) :: MediaFile.t() | nil
  def get_media_file(id, opts \\ []) do
    MediaFile
    |> maybe_preload(opts[:preload])
    |> Repo.get(id)
  end

  @doc """
  Gets adjacent media files (previous and next) for navigation.

  Files are ordered by insertion date (newest first) to match the default
  listing order in the adult library index.

  ## Options
    - `:library_path_type` - Filter by library path type (e.g., :adult)

  Returns `{previous_file, next_file}` where either can be nil if at the boundary.
  """
  @spec get_adjacent_media_files(binary(), keyword()) ::
          {MediaFile.t() | nil, MediaFile.t() | nil}
  def get_adjacent_media_files(current_file_id, opts \\ []) do
    # Build base query with optional library type filter
    base_query =
      MediaFile
      |> apply_media_file_filters(opts)
      |> order_by([f], desc: f.inserted_at, desc: f.id)

    # Get the current file to find its position
    current_file = Repo.get!(MediaFile, current_file_id)

    # Previous file: files inserted after the current one (newer)
    previous_file =
      base_query
      |> where(
        [f],
        f.inserted_at > ^current_file.inserted_at or
          (f.inserted_at == ^current_file.inserted_at and f.id > ^current_file_id)
      )
      |> order_by([f], asc: f.inserted_at, asc: f.id)
      |> limit(1)
      |> Repo.one()

    # Next file: files inserted before the current one (older)
    next_file =
      base_query
      |> where(
        [f],
        f.inserted_at < ^current_file.inserted_at or
          (f.inserted_at == ^current_file.inserted_at and f.id < ^current_file_id)
      )
      |> limit(1)
      |> Repo.one()

    {previous_file, next_file}
  end

  @doc """
  Gets a media file by absolute path.

  Matches the path against all library paths to find the relative path,
  then queries by relative_path and library_path_id.

  Returns nil if no matching file is found.
  """
  @spec get_media_file_by_path(String.t(), keyword()) :: MediaFile.t() | nil
  def get_media_file_by_path(absolute_path, opts \\ []) do
    alias Mydia.Settings

    # Get all library paths to match the absolute path
    library_paths = Settings.list_library_paths()

    # Calculate relative path and library_path_id
    {library_path_id, relative_path} = calculate_relative_path(absolute_path, library_paths)

    case {library_path_id, relative_path} do
      {nil, _} ->
        # No matching library path found
        nil

      {_, nil} ->
        # No relative path calculated
        nil

      {lp_id, rel_path} ->
        # Query by relative_path and library_path_id
        get_media_file_by_relative_path(lp_id, rel_path, opts)
    end
  end

  @doc """
  Gets a media file by its relative path and library_path_id.
  """
  @spec get_media_file_by_relative_path(binary(), String.t(), keyword()) :: MediaFile.t() | nil
  def get_media_file_by_relative_path(library_path_id, relative_path, opts \\ []) do
    query =
      MediaFile
      |> where([f], f.library_path_id == ^library_path_id and f.relative_path == ^relative_path)

    query =
      if Keyword.get(opts, :include_trashed, false),
        do: query,
        else: where(query, [f], is_nil(f.trashed_at))

    query
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Returns true when the episode already has a media file that has not been trashed.

  Used by the importer to skip season-pack files for episodes the library
  already has, since nothing downstream reconciles two live files for one
  episode outside the upgrade path.
  """
  @spec episode_has_media_file?(String.t()) :: boolean()
  def episode_has_media_file?(episode_id) when is_binary(episode_id) do
    Repo.exists?(
      from(f in MediaFile, where: f.episode_id == ^episode_id and is_nil(f.trashed_at))
    )
  end

  @doc """
  Creates a media file.
  """
  @spec create_media_file(map()) :: {:ok, MediaFile.t()} | {:error, Ecto.Changeset.t()}
  def create_media_file(attrs \\ %{}) do
    %MediaFile{}
    |> MediaFile.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a media file during library scanning.
  Parent association is optional and will be set later during metadata enrichment.

  Returns immediately without running ffprobe. Tech metadata (codec, resolution,
  container, etc.) is populated asynchronously by `Mydia.Jobs.FileAnalysis` or
  the lazy fallback in `Mydia.Streaming.Candidates`, both keyed off
  `analyzed_at IS NULL`.
  """
  @spec create_scanned_media_file(map()) :: {:ok, MediaFile.t()} | {:error, Ecto.Changeset.t()}
  def create_scanned_media_file(attrs \\ %{}) do
    %MediaFile{}
    |> MediaFile.scan_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a media file.
  """
  @spec update_media_file(MediaFile.t(), map()) ::
          {:ok, MediaFile.t()} | {:error, Ecto.Changeset.t()}
  def update_media_file(%MediaFile{} = media_file, attrs) do
    media_file
    |> MediaFile.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a media file during library scanning.

  Uses scan_changeset which allows orphaned files (files not yet matched to
  a media_item or episode) to be updated without validation errors.
  """
  @spec update_media_file_scan(MediaFile.t(), map()) ::
          {:ok, MediaFile.t()} | {:error, Ecto.Changeset.t()}
  def update_media_file_scan(%MediaFile{} = media_file, attrs) do
    media_file
    |> MediaFile.scan_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Marks a media file as verified.
  """
  @spec verify_media_file(MediaFile.t()) :: {:ok, MediaFile.t()} | {:error, Ecto.Changeset.t()}
  def verify_media_file(%MediaFile{} = media_file) do
    media_file
    |> Ecto.Changeset.change(verified_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc """
  Applies a `FileAnalyzer.analyze/1` outcome to a `MediaFile` row.

  Two branches:

    * `{:ok, %FileAnalysisResult{}}` performs a guarded write
      (`UPDATE ... WHERE id = ? AND analyzed_at IS NULL`) that sets every
      tech-metadata column, populates `analyzed_at`, clears
      `last_analysis_error`, and bumps `updated_at`. Returns `:ok` when the
      write landed, `:already_analyzed` when another writer beat us.
    * `{:error, reason}` increments `analysis_attempts` and records
      `last_analysis_error` without touching tech metadata. Returns the
      original `{:error, reason}` so callers can decide how to surface it.

  Used by the recurring analysis worker, the lazy-on-play fallback in
  `Mydia.Streaming.Candidates`, and the operator-triggered
  `refresh_file_metadata/1`. The `WHERE analyzed_at IS NULL` guard makes
  concurrent writers safe: only the first success-write lands.
  """
  @spec apply_analysis(
          MediaFile.t(),
          {:ok, Mydia.Library.Structs.FileAnalysisResult.t()} | {:error, term()}
        ) :: :ok | :already_analyzed | {:error, term()}
  def apply_analysis(
        %MediaFile{} = media_file,
        {:ok, %Mydia.Library.Structs.FileAnalysisResult{} = result}
      ) do
    case apply_analysis_success(media_file, result) do
      :ok ->
        maybe_enqueue_upgrade_finalize(media_file)
        :ok

      other ->
        other
    end
  end

  def apply_analysis(%MediaFile{} = media_file, {:error, reason}) do
    apply_analysis_failure(media_file, reason)
  end

  # Enqueues Mydia.Jobs.UpgradeFinalize the moment a file that supersedes
  # another finishes analysis — the first point it can be scored against its
  # profile, and therefore the first point the upgrade/reject decision in
  # Mydia.Upgrades.finalize_upgrade/1 can be made. apply_analysis_success/2
  # only returns :ok on the actual nil -> analyzed transition (a
  # re-analysis returns :already_analyzed), so this fires exactly once per
  # import, never on a re-analysis of the same file.
  defp maybe_enqueue_upgrade_finalize(%MediaFile{supersedes_media_file_id: nil}), do: :ok

  defp maybe_enqueue_upgrade_finalize(%MediaFile{
         id: media_file_id,
         supersedes_media_file_id: supersedes_id
       })
       when is_binary(supersedes_id) do
    alias Mydia.Jobs.UpgradeFinalize

    changeset = UpgradeFinalize.new(%{"media_file_id" => media_file_id})

    case insert_upgrade_finalize_job(changeset) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue UpgradeFinalize",
          media_file_id: media_file_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp insert_upgrade_finalize_job(changeset) do
    Oban.insert(changeset)
  rescue
    RuntimeError -> Repo.insert(changeset)
  end

  defp apply_analysis_success(%MediaFile{} = media_file, result) do
    apply_analysis_success(media_file, result, 3)
  end

  defp apply_analysis_success(%MediaFile{} = media_file, result, retries_remaining) do
    alias Mydia.Library.Structs.FileMetadata
    alias Mydia.Streaming.Codec

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    current =
      Repo.one(
        from(mf in MediaFile,
          where: mf.id == ^media_file.id,
          select: %{
            metadata: mf.metadata,
            analyzed_at: mf.analyzed_at,
            updated_at: mf.updated_at
          }
        )
      )

    if is_nil(current) or current.analyzed_at do
      :already_analyzed
    else
      current_metadata = current.metadata || FileMetadata.empty()

      metadata =
        current_metadata
        |> maybe_put_struct_field(:duration, result.duration)
        |> maybe_put_struct_field(:container, result.container)
        |> maybe_put_struct_field(:width, result.width)
        |> maybe_put_struct_field(:height, result.height)
        |> maybe_put_struct_field(:streams, result.streams)
        # The `audio_codec` column below is normalized for streaming
        # compatibility, which collapses "DD+ 5.1" to "ac3" and "TrueHD Atmos"
        # to "truehd" — losing the channel layout and the Atmos/E-AC3
        # distinction that quality scoring needs. Keep the analyzer's own
        # string so `Mydia.Upgrades.Attrs` has something lossless to read.
        |> maybe_put_struct_field(:audio_codec_raw, result.audio_codec)

      write_analysis_success(
        media_file,
        result,
        metadata,
        current.updated_at,
        now,
        retries_remaining
      )
    end
  end

  defp write_analysis_success(
         media_file,
         result,
         metadata,
         expected_updated_at,
         now,
         retries_remaining
       ) do
    alias Mydia.Streaming.Codec

    set = [
      codec: Codec.normalize_video_codec(result.codec),
      audio_codec: Codec.normalize_audio_codec(result.audio_codec),
      resolution: result.resolution,
      bitrate: result.bitrate,
      hdr_format: result.hdr_format,
      metadata: metadata,
      analyzed_at: now,
      analysis_attempts: 0,
      last_analysis_error: nil,
      updated_at: now
    ]

    # `size` is set only when ffprobe surfaced a value; otherwise we leave the
    # existing column alone so we do not overwrite a known size with nil.
    set = if result.size, do: Keyword.put(set, :size, result.size), else: set

    query =
      from(mf in MediaFile,
        where:
          mf.id == ^media_file.id and is_nil(mf.analyzed_at) and
            mf.updated_at == ^expected_updated_at
      )

    case Repo.update_all(query, set: set) do
      {1, _} ->
        :ok

      {0, _} when retries_remaining > 0 ->
        apply_analysis_success(media_file, result, retries_remaining - 1)

      {0, _} ->
        :already_analyzed
    end
  end

  defp apply_analysis_failure(%MediaFile{} = media_file, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reason_text = format_analysis_error(reason)

    # Guard against stale-failure writes: if another writer has already
    # populated analyzed_at, do not bump the attempts counter on what is now
    # a known-good row.
    query =
      from(mf in MediaFile,
        where: mf.id == ^media_file.id and is_nil(mf.analyzed_at)
      )

    Repo.update_all(query,
      inc: [analysis_attempts: 1],
      set: [last_analysis_error: reason_text, updated_at: now]
    )

    {:error, reason}
  end

  @doc """
  Clears analysis state on a `MediaFile` row so the next worker tick or
  manual retry treats it as un-analyzed again.

  Resets `analyzed_at`, `analysis_attempts`, and `last_analysis_error`.
  Intended as the building block for an operator-triggered retry surface.
  """
  @spec reset_analysis_state(MediaFile.t()) :: :ok | {:error, :not_found}
  def reset_analysis_state(%MediaFile{} = media_file) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query = from(mf in MediaFile, where: mf.id == ^media_file.id)

    case Repo.update_all(query,
           set: [
             analyzed_at: nil,
             analysis_attempts: 0,
             last_analysis_error: nil,
             updated_at: now
           ]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  defp maybe_put_struct_field(struct, _field, nil), do: struct
  defp maybe_put_struct_field(struct, field, value), do: Map.put(struct, field, value)

  defp record_repair_failure(%MediaFile{} = media_file, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reason_text = format_analysis_error(reason)

    query = from(mf in MediaFile, where: mf.id == ^media_file.id)

    Repo.update_all(query,
      inc: [analysis_attempts: 1],
      set: [last_analysis_error: reason_text, updated_at: now]
    )
  end

  defp apply_repair_analysis(%MediaFile{} = media_file, result) do
    apply_repair_analysis(media_file, result, 3)
  end

  defp apply_repair_analysis(%MediaFile{} = media_file, result, retries_remaining) do
    alias Mydia.Library.Structs.FileMetadata

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    current =
      Repo.one(
        from(mf in MediaFile,
          where: mf.id == ^media_file.id,
          select: %{
            metadata: mf.metadata,
            analyzed_at: mf.analyzed_at,
            updated_at: mf.updated_at
          }
        )
      )

    case current do
      nil ->
        {:error, :not_found}

      current ->
        metadata =
          current.metadata
          |> Kernel.||(FileMetadata.empty())
          |> maybe_put_struct_field(:duration, result.duration)
          |> maybe_put_struct_field(:container, result.container)
          |> maybe_put_struct_field(:width, result.width)
          |> maybe_put_struct_field(:height, result.height)
          |> maybe_put_struct_field(:streams, result.streams)

        set = build_analysis_success_set(result, metadata, now)

        # This guard must stay in lockstep with FileAnalysis.fetch_repair_rows/3
        # and repair_candidate?/1. If it is narrower than the selection, the
        # lane re-probes the same rows on every tick and writes nothing.
        query =
          from(mf in MediaFile,
            where:
              mf.id == ^media_file.id and mf.updated_at == ^current.updated_at and
                mf.analyzed_at == ^current.analyzed_at and
                (is_nil(json_extract(mf.metadata, "$.width")) or
                   is_nil(json_extract(mf.metadata, "$.height")) or
                   is_nil(json_extract(mf.metadata, "$.streams")))
          )

        case Repo.update_all(query, set: set) do
          {1, _} ->
            :ok

          {0, _} when retries_remaining > 0 ->
            apply_repair_analysis(media_file, result, retries_remaining - 1)

          {0, _} ->
            {:error, :not_found}
        end
    end
  end

  defp build_analysis_success_set(result, metadata, now) do
    alias Mydia.Streaming.Codec

    set = [
      codec: Codec.normalize_video_codec(result.codec),
      audio_codec: Codec.normalize_audio_codec(result.audio_codec),
      resolution: result.resolution,
      bitrate: result.bitrate,
      hdr_format: result.hdr_format,
      metadata: metadata,
      analyzed_at: now,
      analysis_attempts: 0,
      last_analysis_error: nil,
      updated_at: now
    ]

    if result.size, do: Keyword.put(set, :size, result.size), else: set
  end

  @max_analysis_error_length 2048

  defp format_analysis_error(reason) when is_atom(reason), do: inspect(reason)
  defp format_analysis_error(reason) when is_binary(reason), do: truncate_analysis_error(reason)
  defp format_analysis_error(reason), do: reason |> inspect() |> truncate_analysis_error()

  defp truncate_analysis_error(reason_text) do
    String.slice(reason_text, 0, @max_analysis_error_length)
  end

  @doc """
  Deletes a media file record, optionally removing the file from disk.

  When `delete_files: true`, the database record is deleted first and only then
  is the physical file (and its NFO sidecar) removed from disk. This ordering is
  deliberate: if the record delete fails the disk is never touched, so nothing is
  lost; and a disk-removal failure after a successful record delete is reported
  via `{:ok, media_file, :file_delete_failed}` (an orphaned file is recoverable,
  an orphaned record pointing at a missing file is not). The file path is
  resolved from the in-memory struct, which is preloaded before the delete so it
  stays available afterwards.

  When `delete_files: false` (the default), only the database record is removed
  and the file is left on disk. This preserves the original arity-1 behavior for
  existing callers.
  """
  @spec delete_media_file(MediaFile.t(), keyword()) ::
          {:ok, MediaFile.t()}
          | {:ok, MediaFile.t(), :file_delete_failed}
          | {:error, Ecto.Changeset.t()}
  def delete_media_file(%MediaFile{} = media_file, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    # Preload the path source before deleting the row so the file is still
    # resolvable from the in-memory struct after the record is gone.
    media_file =
      if delete_files, do: Repo.preload(media_file, :library_path), else: media_file

    case Repo.delete(media_file) do
      {:ok, deleted} when delete_files ->
        case delete_media_file_from_disk(media_file) do
          :ok -> {:ok, deleted}
          {:error, _reason} -> {:ok, deleted, :file_delete_failed}
        end

      {:ok, deleted} ->
        {:ok, deleted}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Moves a media file to trash: the file leaves the library path for the trash
  directory, and `trashed_at` is stamped on the row.

  Trashed files are excluded from all queries by default and are permanently
  deleted after the configured retention period (default 30 days).

  The file has to physically move, not just get a timestamp. Trashed rows are
  invisible to `list_media_files/1`, so a file left sitting on the library path
  is seen by the next scan as a *new* file, matched back to the trashed row by
  relative path, and restored - which silently reverted every automatic quality
  upgrade and resurrected every release rejected for lying about its contents.
  See `Mydia.Library.TrashStore` for where the trash lives and why.

  A file that is already gone from disk stays a normal outcome: that is the
  original reason this function exists (marking what a scan found missing).
  That case is recorded on the row as `"trashed_missing"`, which is what stops
  `TrashCleanup` from later deleting a file that has since come back at the
  library path - an unmounted share that a scan read as a deleted library, for
  instance. See `Mydia.Library.TrashStore.discard/2`.

  Returns `{:error, reason}` without touching the row when a file that *is*
  present could not be moved. A row marked trashed while its file sits in the
  library is precisely the inconsistency this move exists to remove, so the two
  are kept in step or neither changes.
  """
  @spec trash_media_file(MediaFile.t()) ::
          {:ok, MediaFile.t()} | {:error, Ecto.Changeset.t()} | {:error, term()}
  def trash_media_file(%MediaFile{} = media_file) do
    media_file = Repo.preload(media_file, :library_path)

    case TrashStore.store(media_file) do
      {:ok, outcome} ->
        media_file
        |> Ecto.Changeset.change(
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          metadata: put_trash_state(media_file.metadata, outcome)
        )
        |> Repo.update()
        |> case do
          {:ok, trashed} ->
            {:ok, trashed}

          {:error, changeset} ->
            # The bytes already moved but the row did not. Put them back
            # rather than leave an active row pointing at an empty path.
            _ = TrashStore.restore(media_file, moved_path(outcome))
            {:error, changeset}
        end

      {:error, reason} ->
        {:error, {:trash_move_failed, reason}}
    end
  end

  @doc """
  Restores a trashed media file: the file moves back to its library path and
  `trashed_at` is cleared.

  A trashed copy that is missing from the trash directory is not an error - the
  row is restored anyway, exactly as it was before trashing moved files at all.

  When the library path is already occupied the trashed copy is deliberately
  left where it is rather than clobbering what is there, and the row keeps
  pointing at it so those bytes stay reclaimable instead of becoming an
  untracked file under `.mydia-trash/`.
  """
  @spec restore_media_file(MediaFile.t()) ::
          {:ok, MediaFile.t()} | {:error, Ecto.Changeset.t()} | {:error, term()}
  def restore_media_file(%MediaFile{} = media_file) do
    media_file = Repo.preload(media_file, :library_path)

    case TrashStore.restore(media_file, trashed_path(media_file)) do
      :ok ->
        media_file
        |> Ecto.Changeset.change(
          trashed_at: nil,
          metadata: drop_trash_state(media_file.metadata)
        )
        |> Repo.update()

      {:ok, :trash_copy_retained} ->
        media_file
        |> Ecto.Changeset.change(trashed_at: nil)
        |> Repo.update()

      {:error, reason} ->
        Logger.error("Could not restore a trashed media file",
          media_file_id: media_file.id,
          reason: inspect(reason)
        )

        {:error, {:trash_restore_failed, reason}}
    end
  end

  @doc """
  Permanently deletes all media files that have been trashed for longer than `days`,
  including the bytes behind them.

  Returns `{:ok, count}` with the number of permanently deleted files.

  Deleting from disk is the other half of
  [#295](https://github.com/getmydia/mydia/issues/295): the purge used to drop
  the row and leave the file forever, so trash retention never reclaimed any
  space.

  A row whose bytes could not be deleted is **kept**, and its count is not
  included in the return value. Dropping it would orphan the file: nothing
  points at a path under `.mydia-trash/<id>/` once its row is gone, so no
  later run would retry the delete and the space would never come back.
  Keeping the row means the next purge tries again, which is the right
  response to the transient failures that cause this - a read-only mount, a
  permissions blip, an I/O error. Rows whose file was already gone still
  purge normally; a missing file is a reached goal state, not a failure.
  """
  @spec purge_old_trashed_media_files(integer()) :: {:ok, non_neg_integer()}
  def purge_old_trashed_media_files(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-days, :day)

    expired =
      from(f in MediaFile,
        where: not is_nil(f.trashed_at) and f.trashed_at < ^cutoff,
        preload: :library_path
      )
      |> Repo.all()

    {discarded, retained} =
      Enum.split_with(expired, &(TrashStore.discard(&1, trash_state(&1)) == :ok))

    if retained != [] do
      Logger.warning(
        "Kept trashed media file rows whose bytes could not be deleted; the next purge will " <>
          "retry them. Dropping the rows would leave the files on disk with nothing tracking " <>
          "them.",
        count: length(retained),
        media_file_ids: Enum.map(retained, & &1.id)
      )
    end

    ids = Enum.map(discarded, & &1.id)

    {count, _} =
      from(f in MediaFile,
        where:
          f.id in ^ids and not is_nil(f.trashed_at) and
            f.trashed_at < ^cutoff
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  # How a row came to be trashed, recorded on the row itself. Three states,
  # and `TrashStore.discard/2` treats all three differently:
  #
  #   * "trashed_path" - the bytes were moved there. Recorded rather than
  #     recomputed so restore and purge do not depend on the trash directory
  #     configuration still resolving the same way later.
  #   * "trashed_missing" - there was nothing on disk to move. Critically,
  #     this is *not* the same as a legacy row even though both leave
  #     "trashed_path" unset: the file may well be present at the library
  #     path now (an unmounted share that came back), and deleting it there
  #     would be silent data loss. See TrashStore.discard/2.
  #   * neither key - a row trashed before TrashStore existed. Its file is
  #     still at the library path and the purge deletes it there (#295).
  defp trash_state(%MediaFile{} = media_file) do
    cond do
      path = trashed_path(media_file) -> {:moved, path}
      trashed_missing?(media_file) -> :missing
      true -> :legacy
    end
  end

  defp trashed_path(%MediaFile{metadata: %FileMetadata{extra: extra}}) when is_map(extra) do
    case extra["trashed_path"] do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp trashed_path(%MediaFile{}), do: nil

  defp trashed_missing?(%MediaFile{metadata: %FileMetadata{extra: extra}}) when is_map(extra),
    do: extra["trashed_missing"] == true

  defp trashed_missing?(%MediaFile{}), do: false

  defp moved_path({:moved, path}), do: path
  defp moved_path(:missing), do: nil

  defp put_trash_state(metadata, {:moved, path}) when is_binary(path) do
    metadata
    |> drop_trash_state()
    |> then(&%{&1 | extra: Map.put(&1.extra, "trashed_path", path)})
  end

  defp put_trash_state(metadata, :missing) do
    metadata
    |> drop_trash_state()
    |> then(&%{&1 | extra: Map.put(&1.extra, "trashed_missing", true)})
  end

  defp drop_trash_state(nil), do: FileMetadata.empty()

  defp drop_trash_state(%FileMetadata{} = metadata) do
    extra =
      (metadata.extra || %{})
      |> Map.delete("trashed_path")
      |> Map.delete("trashed_missing")

    %{metadata | extra: extra}
  end

  @doc """
  Deletes the physical file from disk for a media file record.

  Returns `:ok` if the file was successfully deleted or doesn't exist,
  `{:error, reason}` if deletion failed.

  This function should be called before deleting the database record
  to ensure the file path is available.

  The library_path association must be preloaded.
  """
  @spec delete_media_file_from_disk(MediaFile.t()) :: :ok | {:error, term()}
  def delete_media_file_from_disk(%MediaFile{} = media_file) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        Logger.error("Cannot delete media file from disk - path could not be resolved",
          media_file_id: media_file.id
        )

        {:error, :path_not_resolved}

      absolute_path ->
        if File.exists?(absolute_path) do
          case File.rm(absolute_path) do
            :ok ->
              Logger.info("Deleted media file from disk", path: absolute_path)
              # Also remove the associated NFO file if it exists
              Mydia.Metadata.NfoWriter.delete_nfo_for_file(absolute_path)
              :ok

            {:error, reason} ->
              Logger.error("Failed to delete media file from disk",
                path: absolute_path,
                reason: inspect(reason)
              )

              {:error, reason}
          end
        else
          # File doesn't exist, consider it a success
          Logger.debug("Media file already doesn't exist on disk", path: absolute_path)
          :ok
        end
    end
  end

  @doc """
  Deletes physical files from disk for a list of media files.

  Returns a tuple `{:ok, success_count, error_count}` with counts of
  successfully deleted and failed deletions.
  """
  @spec delete_media_files_from_disk([MediaFile.t()]) ::
          {:ok, non_neg_integer(), non_neg_integer()}
  def delete_media_files_from_disk(media_files) when is_list(media_files) do
    results =
      Enum.map(media_files, fn file ->
        delete_media_file_from_disk(file)
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    error_count = Enum.count(results, &match?({:error, _}, &1))

    Logger.info("Bulk file deletion from disk completed",
      success: success_count,
      errors: error_count,
      total: length(media_files)
    )

    {:ok, success_count, error_count}
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking media file changes.
  """
  @spec change_media_file(MediaFile.t(), map()) :: Ecto.Changeset.t()
  def change_media_file(%MediaFile{} = media_file, attrs \\ %{}) do
    MediaFile.changeset(media_file, attrs)
  end

  @doc """
  Gets all media files for a media item.
  """
  @spec get_media_files_for_item(binary(), keyword()) :: [MediaFile.t()]
  def get_media_files_for_item(media_item_id, opts \\ []) do
    list_media_files([media_item_id: media_item_id] ++ opts)
  end

  @doc """
  Gets all media files for an episode.
  """
  @spec get_media_files_for_episode(binary(), keyword()) :: [MediaFile.t()]
  def get_media_files_for_episode(episode_id, opts \\ []) do
    list_media_files([episode_id: episode_id] ++ opts)
  end

  @doc """
  Matches unassociated media files to their episodes for a TV show.

  Finds all media files that are linked to a media_item but not to specific episodes,
  parses their filenames to extract season/episode information, and associates them
  with the correct episode records.

  Returns `{:ok, matched_count}` where matched_count is the number of files that
  were successfully matched to episodes.

  ## Parameters
    - `media_item_id` - The ID of the TV show media item

  ## Examples

      iex> match_files_to_episodes("some-uuid")
      {:ok, 8}
  """
  @spec match_files_to_episodes(binary()) :: {:ok, non_neg_integer()}
  def match_files_to_episodes(media_item_id) do
    # Get all media files for this item that don't have an episode_id
    unmatched_files =
      MediaFile
      |> where([mf], mf.media_item_id == ^media_item_id)
      |> where([mf], is_nil(mf.episode_id))
      |> where([mf], is_nil(mf.trashed_at))
      |> Repo.all()

    Logger.info(
      "Found #{length(unmatched_files)} unmatched files for media item #{media_item_id}"
    )

    # Title of the show these files are being matched against, used to reject a
    # stray file whose filename clearly belongs to a different show (see
    # title_belongs_to_other_show?/2).
    show_title = media_item_title(media_item_id)

    # Match each file to an episode
    matched_count =
      Enum.reduce(unmatched_files, 0, fn media_file, count ->
        case match_file_to_episode(media_file, media_item_id, show_title) do
          {:ok, _} -> count + 1
          {:error, _} -> count
        end
      end)

    Logger.info("Successfully matched #{matched_count} files to episodes")

    {:ok, matched_count}
  end

  defp match_file_to_episode(media_file, media_item_id, show_title) do
    # Use relative_path for filename parsing
    filename =
      case media_file.relative_path do
        nil ->
          Logger.warning("Media file missing relative_path during episode matching",
            media_file_id: media_file.id
          )

          # Cannot match without relative_path
          nil

        relative_path ->
          Path.basename(relative_path)
      end

    # Parse the filename to extract season/episode information
    if is_nil(filename) do
      {:error, :no_relative_path}
    else
      parsed_info = FileParser.parse(filename)
      season = parsed_info.season
      episode_numbers = parsed_info.episodes

      cond do
        not (is_integer(season) and is_list(episode_numbers) and episode_numbers != []) ->
          Logger.debug("File did not contain valid episode information", filename: filename)
          {:error, :no_episode_info}

        title_belongs_to_other_show?(parsed_info.title, show_title) ->
          # A file carrying an SxxEyy pattern must not be bound to this show
          # purely because the numbers line up — e.g. a stray "Shark Tank India
          # S04E07" must not match "FROM" S04E07. Guard on the parsed title.
          Logger.debug("Skipping file: parsed title belongs to a different show",
            filename: filename,
            parsed_title: parsed_info.title,
            show_title: show_title
          )

          {:error, :title_mismatch}

        true ->
          match_parsed_episode(media_file, media_item_id, filename, season, episode_numbers)
      end
    end
  end

  # Rejects a file whose parsed title clearly belongs to a different show. Only
  # guards when both a parsed title and a show title are present; an
  # unparseable/blank title falls through so ambiguous filenames keep matching
  # on season/episode numbers as before.
  @title_match_threshold 0.5
  defp title_belongs_to_other_show?(parsed_title, show_title)
       when is_binary(parsed_title) and is_binary(show_title) and
              parsed_title != "" and show_title != "" do
    Text.title_similarity(parsed_title, show_title) < @title_match_threshold
  end

  defp title_belongs_to_other_show?(_parsed_title, _show_title), do: false

  defp media_item_title(media_item_id) do
    case Repo.get(Mydia.Media.MediaItem, media_item_id) do
      %{title: title} -> title
      _ -> nil
    end
  end

  defp match_parsed_episode(media_file, media_item_id, filename, season, episode_numbers) do
    # For multi-episode files, we'll just match to the first episode
    episode_number = List.first(episode_numbers)

    # Find the matching episode
    case Mydia.Media.get_episode_by_number(media_item_id, season, episode_number) do
      nil ->
        Logger.debug("No episode found for file",
          filename: filename,
          season: season,
          episode: episode_number
        )

        {:error, :episode_not_found}

      episode ->
        # Update the media file with the episode_id
        case update_media_file(media_file, %{
               media_item_id: nil,
               episode_id: episode.id
             }) do
          {:ok, updated_file} ->
            Logger.debug("Matched file to episode",
              filename: filename,
              season: season,
              episode: episode_number,
              episode_id: episode.id
            )

            {:ok, updated_file}

          {:error, reason} ->
            Logger.warning("Failed to update media file",
              filename: filename,
              reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  end

  @doc """
  Re-scans a TV series directory to discover and import new episode files.

  This function performs a comprehensive re-scan of a TV series:
  1. Finds the series base directory from existing media files
  2. Scans the directory for all video files
  3. Creates MediaFile records for newly discovered files
  4. Refreshes episode metadata from TMDB
  5. Matches files to episodes

  Returns `{:ok, result_map}` with statistics about the re-scan, or `{:error, reason}`.

  ## Result Map
    - `:new_files` - Number of new files discovered and added
    - `:matched` - Number of files matched to episodes
    - `:errors` - List of error tuples for files that failed to process

  ## Examples

      iex> rescan_series("media-item-uuid")
      {:ok, %{new_files: 3, matched: 3, errors: []}}
  """
  @spec rescan_series(binary()) :: {:ok, map()} | {:error, term()}
  def rescan_series(media_item_id) do
    alias Mydia.Library.Scanner
    alias Mydia.Media
    alias Mydia.Settings

    # Get media item and verify it's a TV show
    media_item = Media.get_media_item!(media_item_id)
    library_paths = Settings.list_library_paths()

    if media_item.type != "tv_show" do
      {:error, :not_a_tv_show}
    else
      # Find base directory from existing media files
      case find_series_base_directory(media_item_id, library_paths) do
        {:ok, base_directory} ->
          Logger.info("Re-scanning TV series",
            media_item_id: media_item_id,
            title: media_item.title,
            directory: base_directory
          )

          # Scan directory for all video files
          case Scanner.scan(base_directory, recursive: true) do
            {:ok, scan_result} ->
              # Get existing media file paths for this series
              existing_files = get_media_files_for_item(media_item_id, preload: [:library_path])

              existing_paths =
                existing_files
                |> Enum.map(&MediaFile.absolute_path/1)
                |> Enum.reject(&is_nil/1)
                |> MapSet.new()

              # Find new files (not already in database)
              new_files =
                scan_result.files
                |> Enum.reject(fn file_info -> MapSet.member?(existing_paths, file_info.path) end)

              # Find files in DB that are no longer on disk
              scanned_paths =
                scan_result.files
                |> Enum.map(& &1.path)
                |> MapSet.new()

              missing_files =
                Enum.reject(existing_files, fn file ->
                  case MediaFile.absolute_path(file) do
                    nil -> true
                    path -> MapSet.member?(scanned_paths, path)
                  end
                end)

              trashed_count =
                Enum.count(missing_files, fn file ->
                  match?({:ok, _}, trash_media_file(file))
                end)

              Logger.info("Found new files during re-scan",
                new_file_count: length(new_files),
                trashed_files: trashed_count,
                total_scanned: length(scan_result.files)
              )

              # Create MediaFile records for new files
              {created_count, create_errors} =
                create_media_files_for_series(new_files, media_item_id, library_paths)

              # Refresh episodes from TMDB to ensure we have all episode metadata
              case Media.refresh_episodes_for_tv_show(media_item, season_monitoring: "all") do
                {:ok, episode_count} ->
                  Logger.info("Refreshed episode metadata",
                    media_item_id: media_item_id,
                    episode_count: episode_count
                  )

                {:error, reason} ->
                  Logger.warning("Failed to refresh episodes during re-scan",
                    media_item_id: media_item_id,
                    reason: inspect(reason)
                  )
              end

              # Match unassociated files to episodes
              {:ok, matched_count} = match_files_to_episodes(media_item_id)

              Logger.info("Re-scan complete",
                media_item_id: media_item_id,
                new_files: created_count,
                deleted_files: trashed_count,
                matched: matched_count,
                errors: length(create_errors)
              )

              {:ok,
               %{
                 new_files: created_count,
                 deleted_files: trashed_count,
                 matched: matched_count,
                 errors: create_errors
               }}

            {:error, :not_found} ->
              # Directory no longer exists — trash all files for the series
              existing_files =
                get_media_files_for_item(media_item_id, preload: [:library_path])

              trashed_count =
                Enum.count(existing_files, fn file ->
                  match?({:ok, _}, trash_media_file(file))
                end)

              Logger.info("Series directory missing, trashed all files",
                media_item_id: media_item_id,
                trashed_files: trashed_count
              )

              {:ok,
               %{
                 new_files: 0,
                 deleted_files: trashed_count,
                 matched: 0,
                 errors: []
               }}

            {:error, reason} ->
              Logger.error("Failed to scan directory",
                directory: base_directory,
                reason: inspect(reason)
              )

              {:error, :scan_failed}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Re-scans a specific season of a TV series to discover and import new episode files.

  Similar to `rescan_series/1` but scoped to a single season.

  Returns `{:ok, result_map}` with statistics about the re-scan, or `{:error, reason}`.

  ## Examples

      iex> rescan_season("media-item-uuid", 1)
      {:ok, %{new_files: 2, matched: 2, errors: []}}
  """
  @spec rescan_season(binary(), integer()) :: {:ok, map()} | {:error, term()}
  def rescan_season(media_item_id, season_number) do
    alias Mydia.Library.Scanner
    alias Mydia.Media
    alias Mydia.Settings

    # Get media item and verify it's a TV show
    media_item = Media.get_media_item!(media_item_id)
    library_paths = Settings.list_library_paths()

    if media_item.type != "tv_show" do
      {:error, :not_a_tv_show}
    else
      # Find base directory from existing media files
      case find_series_base_directory(media_item_id, library_paths) do
        {:ok, base_directory} ->
          Logger.info("Re-scanning TV series season",
            media_item_id: media_item_id,
            title: media_item.title,
            season: season_number,
            directory: base_directory
          )

          # Scan directory for all video files
          case Scanner.scan(base_directory, recursive: true) do
            {:ok, scan_result} ->
              # Parse all scanned files and filter to this season
              season_files =
                scan_result.files
                |> Enum.filter(fn file_info ->
                  parsed = FileParser.parse(Path.basename(file_info.path))
                  parsed.season == season_number
                end)

              # Get existing media file paths for this series (with episode for season scoping)
              existing_files =
                get_media_files_for_item(media_item_id, preload: [:library_path, :episode])

              existing_paths =
                existing_files
                |> Enum.map(&MediaFile.absolute_path/1)
                |> Enum.reject(&is_nil/1)
                |> MapSet.new()

              # Find new files for this season
              new_files =
                season_files
                |> Enum.reject(fn file_info -> MapSet.member?(existing_paths, file_info.path) end)

              # Find files in DB for this season that are no longer on disk
              scanned_paths =
                season_files
                |> Enum.map(& &1.path)
                |> MapSet.new()

              missing_files =
                existing_files
                |> Enum.filter(fn file ->
                  # Only consider files belonging to this season
                  belongs_to_season =
                    cond do
                      file.episode && file.episode.season_number == season_number ->
                        true

                      is_nil(file.episode) ->
                        # Unmatched file: use filename parsing to determine season
                        parsed = FileParser.parse(Path.basename(file.relative_path || ""))
                        parsed.season == season_number

                      true ->
                        false
                    end

                  belongs_to_season &&
                    case MediaFile.absolute_path(file) do
                      nil -> false
                      path -> not MapSet.member?(scanned_paths, path)
                    end
                end)

              trashed_count =
                Enum.count(missing_files, fn file ->
                  match?({:ok, _}, trash_media_file(file))
                end)

              Logger.info("Found new files for season during re-scan",
                season: season_number,
                new_file_count: length(new_files),
                trashed_files: trashed_count,
                total_season_files: length(season_files)
              )

              # Create MediaFile records for new files
              {created_count, create_errors} =
                create_media_files_for_series(new_files, media_item_id, library_paths)

              # Refresh episodes from TMDB for this season
              case Media.refresh_episodes_for_tv_show(media_item, season_monitoring: "all") do
                {:ok, episode_count} ->
                  Logger.info("Refreshed episode metadata for season",
                    media_item_id: media_item_id,
                    season: season_number,
                    episode_count: episode_count
                  )

                {:error, reason} ->
                  Logger.warning("Failed to refresh episodes during season re-scan",
                    media_item_id: media_item_id,
                    season: season_number,
                    reason: inspect(reason)
                  )
              end

              # Match unassociated files to episodes (will match all seasons, but that's fine)
              {:ok, matched_count} = match_files_to_episodes(media_item_id)

              Logger.info("Season re-scan complete",
                media_item_id: media_item_id,
                season: season_number,
                new_files: created_count,
                deleted_files: trashed_count,
                matched: matched_count,
                errors: length(create_errors)
              )

              {:ok,
               %{
                 new_files: created_count,
                 deleted_files: trashed_count,
                 matched: matched_count,
                 errors: create_errors
               }}

            {:error, :not_found} ->
              # Directory no longer exists — trash all season files
              existing_files =
                get_media_files_for_item(media_item_id, preload: [:library_path, :episode])

              season_existing =
                Enum.filter(existing_files, fn file ->
                  cond do
                    file.episode && file.episode.season_number == season_number ->
                      true

                    is_nil(file.episode) ->
                      parsed = FileParser.parse(Path.basename(file.relative_path || ""))
                      parsed.season == season_number

                    true ->
                      false
                  end
                end)

              trashed_count =
                Enum.count(season_existing, fn file ->
                  match?({:ok, _}, trash_media_file(file))
                end)

              Logger.info("Season directory missing, trashed season files",
                media_item_id: media_item_id,
                season: season_number,
                trashed_files: trashed_count
              )

              {:ok,
               %{
                 new_files: 0,
                 deleted_files: trashed_count,
                 matched: 0,
                 errors: []
               }}

            {:error, reason} ->
              Logger.error("Failed to scan directory for season",
                directory: base_directory,
                season: season_number,
                reason: inspect(reason)
              )

              {:error, :scan_failed}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Re-scans a movie's directory for new files and creates MediaFile records.

  Discovers new video files in the movie's directory that aren't already
  in the database. For each new file, creates a MediaFile record and refreshes
  FFprobe metadata.

  Returns `{:ok, result_map}` with statistics about the re-scan, or `{:error, reason}`.

  ## Result Map
    - `:new_files` - Number of new files discovered and added
    - `:errors` - List of error tuples for files that failed to process

  ## Examples

      iex> rescan_movie("media-item-uuid")
      {:ok, %{new_files: 1, errors: []}}
  """
  @spec rescan_movie(binary()) :: {:ok, map()} | {:error, term()}
  def rescan_movie(media_item_id) do
    alias Mydia.Library.Scanner
    alias Mydia.Media
    alias Mydia.Settings

    # Get media item and verify it's a movie
    media_item = Media.get_media_item!(media_item_id)
    library_paths = Settings.list_library_paths()

    if media_item.type != "movie" do
      {:error, :not_a_movie}
    else
      # Find base directory from existing media files
      case find_movie_base_directory(media_item_id, library_paths) do
        {:ok, base_directory} ->
          Logger.info("Re-scanning movie",
            media_item_id: media_item_id,
            title: media_item.title,
            directory: base_directory
          )

          # Scan directory for video files (not recursive for movies)
          case Scanner.scan(base_directory, recursive: false) do
            {:ok, scan_result} ->
              # Get existing media file paths for this movie
              existing_files = get_media_files_for_item(media_item_id, preload: [:library_path])

              existing_paths =
                existing_files
                |> Enum.map(&MediaFile.absolute_path/1)
                |> Enum.reject(&is_nil/1)
                |> MapSet.new()

              # Find new files (not already in database)
              new_files =
                scan_result.files
                |> Enum.reject(fn file_info -> MapSet.member?(existing_paths, file_info.path) end)

              # Find files in DB that are no longer on disk
              scanned_paths =
                scan_result.files
                |> Enum.map(& &1.path)
                |> MapSet.new()

              missing_files =
                Enum.reject(existing_files, fn file ->
                  case MediaFile.absolute_path(file) do
                    nil -> true
                    path -> MapSet.member?(scanned_paths, path)
                  end
                end)

              trashed_count =
                Enum.count(missing_files, fn file ->
                  match?({:ok, _}, trash_media_file(file))
                end)

              Logger.info("Found new files during movie re-scan",
                new_file_count: length(new_files),
                trashed_files: trashed_count,
                total_scanned: length(scan_result.files)
              )

              # Create MediaFile records for new files
              {created_count, create_errors} =
                create_media_files_for_movie(new_files, media_item_id, library_paths)

              Logger.info("Movie re-scan complete",
                media_item_id: media_item_id,
                new_files: created_count,
                deleted_files: trashed_count,
                errors: length(create_errors)
              )

              {:ok,
               %{
                 new_files: created_count,
                 deleted_files: trashed_count,
                 errors: create_errors
               }}

            {:error, :not_found} ->
              # Directory no longer exists — trash all files for the movie
              existing_files =
                get_media_files_for_item(media_item_id, preload: [:library_path])

              trashed_count =
                Enum.count(existing_files, fn file ->
                  match?({:ok, _}, trash_media_file(file))
                end)

              Logger.info("Movie directory missing, trashed all files",
                media_item_id: media_item_id,
                trashed_files: trashed_count
              )

              {:ok,
               %{
                 new_files: 0,
                 deleted_files: trashed_count,
                 errors: []
               }}

            {:error, reason} ->
              Logger.error("Failed to scan directory",
                directory: base_directory,
                reason: inspect(reason)
              )

              {:error, :scan_failed}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Finds the base directory for a TV series by looking at existing media file paths
  # Safety check: never allow scanning from a library path root.
  # Scanning the entire library would import every item as one media item.
  defp guard_not_library_root(dir, media_item_id, library_paths) do
    library_path_roots =
      library_paths
      |> Enum.map(& &1.path)
      |> MapSet.new()

    if MapSet.member?(library_path_roots, dir) do
      Logger.error("Detected directory is a library root — refusing to scan",
        media_item_id: media_item_id,
        directory: dir
      )

      {:error, :directory_is_library_root}
    else
      {:ok, dir}
    end
  end

  defp find_series_base_directory(media_item_id, library_paths) do
    media_files = get_media_files_for_item(media_item_id, preload: [:episode, :library_path])

    case media_files do
      [] ->
        Logger.warning("No media files found for series",
          media_item_id: media_item_id
        )

        {:error, :no_media_files}

      files ->
        # Extract the series folder name from each file's relative_path.
        # relative_path is like "SeriesName/Season 01/file.mkv" or "SeriesName/file.mkv"
        # The first path component is always the series folder.
        series_dirs =
          files
          |> Enum.map(fn file ->
            case {file.relative_path, file.library_path} do
              {nil, _} ->
                nil

              {_, nil} ->
                nil

              {relative_path, library_path} ->
                parts = Path.split(relative_path)

                # Guard: relative_path must have at least 2 components (folder/file).
                # A single component means the file is directly in the library root
                # with no series folder, which shouldn't happen for TV shows.
                if length(parts) >= 2 do
                  series_folder = List.first(parts)
                  Path.join(library_path.path, series_folder)
                end
            end
          end)
          |> Enum.reject(&is_nil/1)

        case series_dirs do
          [] ->
            Logger.error("Could not determine series base directory - no valid paths",
              media_item_id: media_item_id
            )

            {:error, :no_valid_paths}

          dirs ->
            # Use the most common series directory
            series_dir =
              dirs
              |> Enum.frequencies()
              |> Enum.max_by(fn {_dir, count} -> count end)
              |> elem(0)

            guard_not_library_root(series_dir, media_item_id, library_paths)
        end
    end
  end

  # Creates MediaFile records for a list of scanned files
  defp create_media_files_for_series(file_infos, media_item_id, library_paths) do
    results =
      Enum.map(file_infos, fn file_info ->
        # Find matching library_path and calculate relative_path
        {library_path_id, relative_path} = calculate_relative_path(file_info.path, library_paths)

        attrs = %{
          relative_path: relative_path,
          library_path_id: library_path_id,
          size: file_info.size,
          media_item_id: media_item_id
        }

        case create_scanned_media_file(attrs) do
          {:ok, media_file} ->
            Logger.debug("Created media file record",
              relative_path: relative_path,
              library_path_id: library_path_id,
              media_file_id: media_file.id
            )

            {:ok, media_file}

          {:error, changeset} ->
            Logger.warning("Failed to create media file record",
              path: file_info.path,
              errors: inspect(changeset.errors)
            )

            {:error, {:create_failed, file_info.path}}
        end
      end)

    created_count = Enum.count(results, &match?({:ok, _}, &1))
    errors = Enum.filter(results, &match?({:error, _}, &1))

    {created_count, errors}
  end

  # Finds the base directory for a movie by looking at existing media file paths
  defp find_movie_base_directory(media_item_id, library_paths) do
    media_files = get_media_files_for_item(media_item_id, preload: [:library_path])

    case media_files do
      [] ->
        Logger.warning("No media files found for movie",
          media_item_id: media_item_id
        )

        {:error, :no_media_files}

      files ->
        # Get the most common directory (movies are typically in a single directory)
        movie_dir =
          files
          |> Enum.map(fn file ->
            case MediaFile.absolute_path(file) do
              nil -> nil
              path -> Path.dirname(path)
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.frequencies()
          |> Enum.max_by(fn {_dir, count} -> count end, fn -> {nil, 0} end)
          |> elem(0)

        case movie_dir do
          nil ->
            Logger.error("Could not determine movie base directory - no valid paths",
              media_item_id: media_item_id
            )

            {:error, :no_valid_paths}

          dir ->
            guard_not_library_root(dir, media_item_id, library_paths)
        end
    end
  end

  # Creates MediaFile records for a list of scanned movie files
  defp create_media_files_for_movie(file_infos, media_item_id, library_paths) do
    results =
      Enum.map(file_infos, fn file_info ->
        # Find matching library_path and calculate relative_path
        {library_path_id, relative_path} = calculate_relative_path(file_info.path, library_paths)

        attrs = %{
          relative_path: relative_path,
          library_path_id: library_path_id,
          size: file_info.size,
          media_item_id: media_item_id
        }

        case create_scanned_media_file(attrs) do
          {:ok, media_file} ->
            Logger.debug("Created media file record for movie",
              relative_path: relative_path,
              library_path_id: library_path_id,
              media_file_id: media_file.id
            )

            {:ok, media_file}

          {:error, changeset} ->
            Logger.warning("Failed to create media file record for movie",
              path: file_info.path,
              errors: inspect(changeset.errors)
            )

            {:error, {:create_failed, file_info.path}}
        end
      end)

    created_count = Enum.count(results, &match?({:ok, _}, &1))
    errors = Enum.filter(results, &match?({:error, _}, &1))

    {created_count, errors}
  end

  @doc """
  Returns orphaned media files (files without media_item_id or episode_id).

  These files were scanned but failed to match to any media items.
  They can be safely re-matched or deleted.

  ## Options
    - `:preload` - List of associations to preload
  """
  @spec list_orphaned_media_files(keyword()) :: [MediaFile.t()]
  def list_orphaned_media_files(opts \\ []) do
    MediaFile
    |> where([f], is_nil(f.media_item_id) and is_nil(f.episode_id))
    |> where([f], is_nil(f.trashed_at))
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Checks if a media file is orphaned (has no parent association).
  """
  @spec orphaned_media_file?(MediaFile.t()) :: boolean()
  def orphaned_media_file?(%MediaFile{} = media_file) do
    is_nil(media_file.media_item_id) and is_nil(media_file.episode_id)
  end

  @doc """
  Finds media files similar to the given file based on perceptual hash.

  Uses the dHash algorithm to compare video content. Files with a Hamming distance
  less than or equal to the threshold are considered similar.

  ## Parameters
    - `media_file` - The MediaFile to find similar files for (must have phash set)
    - `opts` - Options:
      - `:threshold` - Maximum Hamming distance to consider similar (default: 10)
      - `:library_path_type` - Filter results to specific library type (e.g., :adult)
      - `:exclude_self` - Whether to exclude the input file from results (default: true)
      - `:preload` - Associations to preload on returned files

  ## Returns
    - `{:ok, similar_files}` - List of similar MediaFile structs with :distance key added
    - `{:error, :no_phash}` - The input file has no perceptual hash

  ## Examples

      {:ok, similar} = Library.find_similar_files(media_file)
      {:ok, similar} = Library.find_similar_files(media_file, threshold: 5)
  """
  @spec find_similar_files(MediaFile.t(), keyword()) ::
          {:ok, list(map())} | {:error, :no_phash}
  def find_similar_files(%MediaFile{phash: nil}, _opts) do
    {:error, :no_phash}
  end

  def find_similar_files(%MediaFile{phash: phash, id: file_id}, opts) do
    threshold = Keyword.get(opts, :threshold, 10)
    exclude_self = Keyword.get(opts, :exclude_self, true)

    # Get all files with phash values
    query =
      MediaFile
      |> where([f], not is_nil(f.phash))
      |> apply_media_file_filters(opts)

    query =
      if exclude_self do
        where(query, [f], f.id != ^file_id)
      else
        query
      end

    files =
      query
      |> maybe_preload(opts[:preload])
      |> Repo.all()

    # Calculate Hamming distance for each file and filter by threshold
    similar_files =
      files
      |> Enum.map(fn file ->
        distance = PhashGenerator.hamming_distance(phash, file.phash)
        {file, distance}
      end)
      |> Enum.filter(fn {_file, distance} -> distance <= threshold end)
      |> Enum.sort_by(fn {_file, distance} -> distance end)
      |> Enum.map(fn {file, distance} ->
        Map.put(file, :distance, distance)
      end)

    {:ok, similar_files}
  end

  @doc """
  Lists potential duplicate files across the library based on perceptual hashing.

  Groups files that are likely duplicates (same or very similar content) based
  on their perceptual hash similarity.

  ## Parameters
    - `opts` - Options:
      - `:threshold` - Maximum Hamming distance for duplicates (default: 5)
      - `:library_path_type` - Filter to specific library type
      - `:min_group_size` - Minimum files in a group to include (default: 2)
      - `:preload` - Associations to preload

  ## Returns
    A list of duplicate groups, where each group is a list of similar files.

  ## Examples

      groups = Library.find_duplicate_files(library_path_type: :adult)
      # Returns: [[file1, file2], [file3, file4, file5], ...]
  """
  @spec find_duplicate_files(keyword()) :: list(list(MediaFile.t()))
  def find_duplicate_files(opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 5)
    min_group_size = Keyword.get(opts, :min_group_size, 2)

    # Get all files with phash values
    files =
      MediaFile
      |> where([f], not is_nil(f.phash))
      |> apply_media_file_filters(opts)
      |> maybe_preload(opts[:preload])
      |> Repo.all()

    # Group files by similarity using union-find approach
    groups = group_similar_files(files, threshold)

    # Filter to groups with at least min_group_size files
    groups
    |> Enum.filter(fn group -> length(group) >= min_group_size end)
    |> Enum.sort_by(fn group -> -length(group) end)
  end

  # Groups files by similarity using a simple clustering approach
  defp group_similar_files(files, threshold) do
    # Build a map of file_id -> file for quick lookup
    file_map = Map.new(files, fn f -> {f.id, f} end)

    # Build adjacency list of similar files
    adjacencies =
      files
      |> Enum.reduce(%{}, fn file, acc ->
        similar_ids =
          files
          |> Enum.filter(fn other ->
            other.id != file.id and
              PhashGenerator.hamming_distance(file.phash, other.phash) <= threshold
          end)
          |> Enum.map(& &1.id)

        Map.put(acc, file.id, similar_ids)
      end)

    # Find connected components
    find_connected_components(files, adjacencies, file_map)
  end

  # Finds connected components in the similarity graph
  defp find_connected_components(files, adjacencies, file_map) do
    # Start with all files unvisited
    all_ids = Enum.map(files, & &1.id) |> MapSet.new()

    {components, _visited} =
      Enum.reduce(all_ids, {[], MapSet.new()}, fn id, {components, visited} ->
        if MapSet.member?(visited, id) do
          {components, visited}
        else
          {component, new_visited} = bfs_component(id, adjacencies, visited)

          if component != [] do
            component_files = Enum.map(component, &Map.get(file_map, &1))
            {[component_files | components], new_visited}
          else
            {components, new_visited}
          end
        end
      end)

    components
  end

  # BFS to find all nodes in a connected component
  defp bfs_component(start_id, adjacencies, visited) do
    do_bfs([start_id], adjacencies, visited, [])
  end

  defp do_bfs([], _adjacencies, visited, component), do: {component, visited}

  defp do_bfs([id | rest], adjacencies, visited, component) do
    if MapSet.member?(visited, id) do
      do_bfs(rest, adjacencies, visited, component)
    else
      new_visited = MapSet.put(visited, id)
      neighbors = Map.get(adjacencies, id, [])
      unvisited_neighbors = Enum.reject(neighbors, &MapSet.member?(new_visited, &1))

      do_bfs(
        rest ++ unvisited_neighbors,
        adjacencies,
        new_visited,
        [id | component]
      )
    end
  end

  ## Private Functions

  # Calculates the relative path and library_path_id for an absolute file path
  # Returns {library_path_id, relative_path}
  defp calculate_relative_path(absolute_path, library_paths) do
    # Find the library_path that this file belongs to (longest matching prefix).
    # Normalize with trailing slash to prevent false matches like /media/tv matching /media/tv_extras.
    matching_path =
      library_paths
      |> Enum.filter(fn lp ->
        normalized = String.trim_trailing(lp.path, "/") <> "/"
        String.starts_with?(absolute_path, normalized)
      end)
      |> Enum.max_by(fn lp -> String.length(lp.path) end, fn -> nil end)

    case matching_path do
      nil ->
        Logger.warning("No matching library path found for file",
          path: absolute_path
        )

        # Return nil for both - the changeset will handle validation
        {nil, nil}

      library_path ->
        # Calculate relative path by removing the library path prefix
        relative_path =
          absolute_path
          |> String.replace_prefix(library_path.path, "")
          |> String.trim_leading("/")

        {library_path.id, relative_path}
    end
  end

  defp apply_media_file_filters(query, opts) do
    # Exclude trashed files by default unless include_trashed: true
    query =
      if Keyword.get(opts, :include_trashed, false),
        do: query,
        else: where(query, [f], is_nil(f.trashed_at))

    Enum.reduce(opts, query, fn
      {:include_trashed, _}, query ->
        query

      {:media_item_id, media_item_id}, query ->
        # For TV shows, files are associated through episodes, not directly
        # So we need to find files where:
        # 1. media_item_id matches directly (for movies/direct associations)
        # 2. episode_id belongs to an episode of this media_item (for TV shows)
        from(f in query,
          left_join: e in assoc(f, :episode),
          where: f.media_item_id == ^media_item_id or e.media_item_id == ^media_item_id
        )

      {:episode_id, episode_id}, query ->
        where(query, [f], f.episode_id == ^episode_id)

      {:library_path_id, library_path_id}, query ->
        # Filter files by library_path_id (for relative path scans)
        where(query, [f], f.library_path_id == ^library_path_id)

      {:library_path_type, library_type}, query ->
        # Filter files by their library path type (e.g., :adult, :music, :books)
        from(f in query,
          join: lp in assoc(f, :library_path),
          where: lp.type == ^library_type
        )

      {:path_prefix, _prefix}, query ->
        # COMPAT: `path_prefix` is superseded by `library_path_id`.
        #
        # Accepts: callers that still pass a path string rather than a
        # library path id.
        # Source: no in-repo caller passes this option today, and no
        # external consumer is known. Retention here is precautionary, not
        # evidence of an actual caller.
        # Removing it would: turn any caller still using it into a
        # match-nothing query with no error, which reads as an empty library.
        Logger.warning("path_prefix filter is deprecated, use library_path_id instead")
        query

      _other, query ->
        query
    end)
  end

  @doc """
  Triggers a manual library scan for a specific library path.

  Returns an Oban job that will perform the scan.
  """
  @spec trigger_library_scan(binary()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def trigger_library_scan(library_path_id) do
    %{library_path_id: library_path_id}
    |> Mydia.Jobs.LibraryScanner.new()
    |> insert_scan_job()
  end

  @doc """
  Triggers a library scan for all monitored library paths.

  ## Options

    - `:schedule_in` - Seconds to wait before the scan runs. Omitted by manual
      triggers, which should start immediately. Automatic callers pass
      `Mydia.Jobs.LibraryScanner.jitter_seconds/0` so that instances restarting
      on the same new image do not hit the metadata relay at once.

  Returns an Oban job that will perform the scan.
  """
  @spec trigger_full_library_scan(keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def trigger_full_library_scan(opts \\ []) do
    %{}
    |> Mydia.Jobs.LibraryScanner.new(Keyword.take(opts, [:schedule_in]))
    |> insert_scan_job()
  end

  @doc """
  Triggers a manual library scan for all adult library paths.

  This will scan for new/modified/deleted files and automatically
  generate thumbnails for any new files.

  Returns an Oban job that will perform the scan.
  """
  @spec trigger_adult_library_scan() :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def trigger_adult_library_scan do
    %{library_type: "adult"}
    |> Mydia.Jobs.LibraryScanner.new()
    |> insert_scan_job()
  end

  # Insert an Oban job, falling back to a direct Repo insert when Oban's
  # engine is disabled (test mode, config/test.exs sets engine: false so no
  # Oban instance is running). Mirrors the pattern used by
  # Mydia.Downloads.Queue.insert_job/1 and Mydia.Jobs.DownloadMonitor.
  defp insert_scan_job(changeset) do
    Oban.insert(changeset)
  rescue
    RuntimeError -> Repo.insert(changeset)
  end

  @doc """
  Triggers a metadata refresh for a specific media item.

  ## Options
    - `:fetch_episodes` - For TV shows, whether to refresh episodes (default: true)

  Returns an Oban job that will perform the refresh.
  """
  @spec trigger_metadata_refresh(binary(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def trigger_metadata_refresh(media_item_id, opts \\ []) do
    fetch_episodes = Keyword.get(opts, :fetch_episodes, true)

    %{media_item_id: media_item_id, fetch_episodes: fetch_episodes}
    |> Mydia.Jobs.MetadataRefresh.new()
    |> Oban.insert()
  end

  @doc """
  Triggers a metadata refresh for all monitored media items.

  Returns an Oban job that will perform the refresh.
  """
  @spec trigger_full_metadata_refresh() :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def trigger_full_metadata_refresh do
    %{refresh_all: true}
    |> Mydia.Jobs.MetadataRefresh.new()
    |> Oban.insert()
  end

  @doc """
  Refreshes file metadata for a specific media file by re-analyzing it.

  Uses both filename parsing and FFprobe analysis, preferring actual file metadata.

  The library_path association must be preloaded.

  Returns {:ok, updated_media_file} or {:error, reason}.
  """
  @spec refresh_file_metadata(MediaFile.t()) :: {:ok, MediaFile.t()} | {:error, term()}
  def refresh_file_metadata(%MediaFile{} = media_file) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        Logger.error("Cannot refresh file metadata - path could not be resolved",
          file_id: media_file.id
        )

        {:error, :path_not_resolved}

      absolute_path ->
        if File.exists?(absolute_path) do
          # Operator-triggered retry: clear analysis_attempts first so the row
          # is no longer blocked by the worker's ceiling, then re-run ffprobe
          # and route the write through apply_analysis/2 to share the guarded
          # write with the worker and the lazy fallback. If the row was deleted
          # mid-flight we surface that cleanly rather than letting the later
          # get_media_file!/2 raise.
          with :ok <- reset_analysis_state(media_file) do
            result = FileAnalyzer.analyze(absolute_path)
            apply_analysis_outcome = apply_analysis(media_file, result)
            handle_refresh_outcome(media_file, absolute_path, apply_analysis_outcome, result)
          end
        else
          Logger.warning("File does not exist, cannot refresh metadata",
            file_id: media_file.id,
            path: absolute_path
          )

          {:error, :file_not_found}
        end
    end
  end

  defp handle_refresh_outcome(media_file, absolute_path, outcome, _result)
       when outcome in [:ok, :already_analyzed] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(mf in MediaFile, where: mf.id == ^media_file.id)
    |> Repo.update_all(set: [verified_at: now])

    updated_file = get_media_file!(media_file.id, preload: [:library_path])

    Logger.info("Refreshed file metadata",
      file_id: media_file.id,
      path: absolute_path,
      resolution: updated_file.resolution,
      codec: updated_file.codec,
      audio: updated_file.audio_codec
    )

    {:ok, updated_file}
  end

  defp handle_refresh_outcome(media_file, _absolute_path, {:error, reason}, _result) do
    Logger.warning("FFprobe analysis failed during refresh",
      file_id: media_file.id,
      reason: inspect(reason)
    )

    {:error, reason}
  end

  @doc """
  Refreshes file metadata for a media file by ID.

  Returns {:ok, updated_media_file} or {:error, reason}.
  """
  @spec refresh_file_metadata_by_id(binary()) :: {:ok, MediaFile.t()} | {:error, term()}
  def refresh_file_metadata_by_id(media_file_id) do
    media_file = get_media_file!(media_file_id, preload: [:library_path])
    refresh_file_metadata(media_file)
  end

  @doc """
  Re-analyzes an already-analyzed file in place without clearing the existing
  analysis state first.

  Intended for self-healing passes that backfill newly tracked metadata fields
  or repair legacy analyzer mistakes while preserving the old row on failure.
  """
  @spec repair_file_metadata(MediaFile.t()) :: {:ok, MediaFile.t()} | {:error, term()}
  def repair_file_metadata(%MediaFile{} = media_file) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        Logger.error("Cannot repair file metadata - path could not be resolved",
          file_id: media_file.id
        )

        {:error, :path_not_resolved}

      absolute_path ->
        if File.exists?(absolute_path) do
          case FileAnalyzer.analyze(absolute_path) do
            {:ok, result} ->
              case apply_repair_analysis(media_file, result) do
                :ok ->
                  updated_file = get_media_file!(media_file.id, preload: [:library_path])

                  Logger.info("Repaired file metadata",
                    file_id: media_file.id,
                    path: absolute_path,
                    resolution: updated_file.resolution,
                    codec: updated_file.codec,
                    audio: updated_file.audio_codec
                  )

                  {:ok, updated_file}

                {:error, :not_found} = error ->
                  error
              end

            {:error, reason} ->
              record_repair_failure(media_file, reason)

              Logger.warning("FFprobe analysis failed during repair",
                file_id: media_file.id,
                reason: inspect(reason)
              )

              {:error, reason}
          end
        else
          Logger.warning("File does not exist, cannot repair metadata",
            file_id: media_file.id,
            path: absolute_path
          )

          {:error, :file_not_found}
        end
    end
  end

  @doc false
  # Test seam for the repair write path, which is otherwise only reachable
  # through repair_file_metadata/1 and therefore through a real ffprobe run.
  def apply_repair_analysis_for_test(%MediaFile{} = media_file, result) do
    apply_repair_analysis(media_file, result)
  end

  @doc """
  Checks if a torrent from a download client has already been imported to the library.

  Returns true if any media_file has this client_id in its metadata, false otherwise.
  This is used to prevent re-processing torrents that are seeding after import.
  """
  @spec torrent_already_imported?(String.t(), String.t()) :: boolean()
  def torrent_already_imported?(client_name, client_id) do
    query =
      from f in MediaFile,
        where: ^Mydia.DB.json_equals(:metadata, "$.download_client", client_name),
        where: ^Mydia.DB.json_equals(:metadata, "$.download_client_id", client_id)

    Repo.exists?(query)
  end

  @doc """
  Batched `torrent_already_imported?/2`: which of `pairs` are already imported.

  `pairs` are `{client_name, client_id}` tuples. Returns the subset found in
  `media_files` provenance, as a MapSet for membership testing.

  Checking one pair at a time costs a query each, which the external-torrent
  scan pays on every pass over every foreign torrent in every client. This
  filters server-side by the exact pairs asked about, so the rows it loads are
  bounded by the candidates rather than by library size.

  Chunked because the filter is an OR-chain of pair conditions and SQLite caps
  expression depth; the chunk size keeps the generated SQL well inside it.
  """
  @spec imported_torrent_pairs([{String.t(), String.t()}]) :: MapSet.t({String.t(), String.t()})
  def imported_torrent_pairs([]), do: MapSet.new()

  def imported_torrent_pairs(pairs) do
    pairs
    |> Enum.uniq()
    |> Enum.chunk_every(100)
    |> Enum.reduce(MapSet.new(), fn chunk, acc ->
      chunk
      |> imported_pairs_chunk()
      |> MapSet.union(acc)
    end)
  end

  defp imported_pairs_chunk(chunk) do
    condition =
      Enum.reduce(chunk, dynamic(false), fn {client_name, client_id}, acc ->
        dynamic(
          ^acc or
            (^Mydia.DB.json_equals(:metadata, "$.download_client", client_name) and
               ^Mydia.DB.json_equals(:metadata, "$.download_client_id", client_id))
        )
      end)

    wanted = MapSet.new(chunk)

    from(f in MediaFile, where: ^condition, select: f.metadata)
    |> Repo.all()
    |> Enum.reduce(MapSet.new(), fn metadata, acc ->
      # download_client / download_client_id are not declared FileMetadata
      # fields, so they live in the `extra` catch-all.
      extra = (metadata && metadata.extra) || %{}
      pair = {extra["download_client"], extra["download_client_id"]}

      if MapSet.member?(wanted, pair), do: MapSet.put(acc, pair), else: acc
    end)
  end

  @doc """
  Lists the media files imported from a given download.

  Located by the collision-free `imported_from_download_id` provenance key — the
  download's primary key, written into `metadata` at import time. The
  `(download_client, download_client_id)` pair is deliberately NOT used as the
  key: download clients recycle torrent/nzb IDs, so that pair is unique only at a
  single instant, not over the file's lifetime, and would surface the wrong file.

  Excludes trashed files. Pass `preload:` to preload associations.
  """
  @spec list_media_files_for_download(Mydia.Downloads.Download.t(), keyword()) :: [MediaFile.t()]
  def list_media_files_for_download(download, opts \\ []) do
    query =
      from f in MediaFile,
        where: ^Mydia.DB.json_equals(:metadata, "$.imported_from_download_id", download.id),
        where: is_nil(f.trashed_at)

    query
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Counts non-trashed imported files per download, keyed by `imported_from_download_id`.

  Batched companion to `list_media_files_for_download/1` for callers that need to
  know how many files a set of downloads imported without an N+1 query — e.g. the
  Downloads LiveView deciding whether a completed row is single-file (re-match
  eligible) or a pack. Returns `%{download_id => count}`; downloads with no
  imported files are simply absent from the map.
  """
  @spec count_imported_files_by_download([binary()]) :: %{binary() => non_neg_integer()}
  def count_imported_files_by_download([]), do: %{}

  def count_imported_files_by_download(download_ids) when is_list(download_ids) do
    ids = Enum.map(download_ids, &to_string/1)

    from(f in MediaFile,
      where: is_nil(f.trashed_at),
      where: json_extract(f.metadata, "$.imported_from_download_id") in ^ids,
      group_by: json_extract(f.metadata, "$.imported_from_download_id"),
      select: {json_extract(f.metadata, "$.imported_from_download_id"), count(f.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Refreshes file metadata for all media files in the library.

  This can be a long-running operation. Returns the count of successfully refreshed files.
  """
  @spec refresh_all_file_metadata() :: {:ok, non_neg_integer()}
  def refresh_all_file_metadata do
    media_files = list_media_files(preload: [:library_path])

    Logger.info("Starting bulk metadata refresh", total_files: length(media_files))

    results =
      Enum.map(media_files, fn file ->
        case refresh_file_metadata(file) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    error_count = Enum.count(results, &(&1 == :error))

    Logger.info("Completed bulk metadata refresh",
      success: success_count,
      errors: error_count
    )

    {:ok, success_count}
  end

  ## Import Sessions

  alias Mydia.Library.ImportSession

  @doc """
  Creates a new import session for a user.
  """
  @spec create_import_session(map()) :: {:ok, ImportSession.t()} | {:error, Ecto.Changeset.t()}
  def create_import_session(attrs \\ %{}) do
    attrs
    |> ImportSession.create_changeset()
    |> Repo.insert()
  end

  @doc """
  Gets the active import session for a user.
  Returns nil if no active session exists.
  """
  @spec get_active_import_session(binary()) :: ImportSession.t() | nil
  def get_active_import_session(user_id) do
    ImportSession
    |> where([s], s.user_id == ^user_id and s.status == :active)
    |> order_by([s], desc: s.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Gets an import session by ID.
  Returns nil if not found.
  """
  @spec get_import_session(binary()) :: ImportSession.t() | nil
  def get_import_session(id) do
    Repo.get(ImportSession, id)
  end

  @doc """
  Gets an import session by ID.
  Raises Ecto.NoResultsError if not found.
  """
  @spec get_import_session!(binary()) :: ImportSession.t()
  def get_import_session!(id) do
    Repo.get!(ImportSession, id)
  end

  @doc """
  Updates an import session.
  """
  @spec update_import_session(ImportSession.t(), map()) ::
          {:ok, ImportSession.t()} | {:error, Ecto.Changeset.t()}
  def update_import_session(%ImportSession{} = session, attrs) do
    session
    |> ImportSession.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Marks an import session as completed.
  """
  @spec complete_import_session(ImportSession.t()) ::
          {:ok, ImportSession.t()} | {:error, Ecto.Changeset.t()}
  def complete_import_session(%ImportSession{} = session) do
    session
    |> ImportSession.complete_changeset()
    |> Repo.update()
  end

  @doc """
  Abandons all active import sessions for a user.
  This is called when starting a new import session.
  """
  @spec abandon_active_import_sessions(binary()) :: {non_neg_integer(), nil | [term()]}
  def abandon_active_import_sessions(user_id) do
    from(s in ImportSession,
      where: s.user_id == ^user_id and s.status == :active
    )
    |> Repo.update_all(
      set: [status: :abandoned, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
  end

  @doc """
  Deletes expired import sessions.
  Returns the count of deleted sessions.
  """
  @spec delete_expired_import_sessions() :: {:ok, non_neg_integer()}
  def delete_expired_import_sessions do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(s in ImportSession,
        where: s.expires_at < ^now
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Deletes completed import sessions older than the given number of days.
  Returns the count of deleted sessions.
  """
  @spec delete_old_completed_sessions(integer()) :: {:ok, non_neg_integer()}
  def delete_old_completed_sessions(days \\ 7) do
    cutoff = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-days, :day)

    {count, _} =
      from(s in ImportSession,
        where: s.status == :completed and s.completed_at < ^cutoff
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  ## Match Candidates

  alias Mydia.Library.MatchCandidate

  @doc """
  Creates or replaces the match candidate at a given rank for a media file.

  Upsert rather than insert so a retried match never doubles up: the matching
  phase is allowed to run again over a file whose previous attempt crashed
  mid-write.
  """
  @spec upsert_match_candidate(map()) :: {:ok, MatchCandidate.t()} | {:error, Ecto.Changeset.t()}
  def upsert_match_candidate(attrs) do
    media_file_id = attrs[:media_file_id] || attrs["media_file_id"]
    rank = attrs[:rank] || attrs["rank"] || 0

    candidate =
      Repo.get_by(MatchCandidate, media_file_id: media_file_id, rank: rank) || %MatchCandidate{}

    candidate
    |> MatchCandidate.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Lists the cached match candidates for a media file, best first.
  """
  @spec list_match_candidates(binary()) :: [MatchCandidate.t()]
  def list_match_candidates(media_file_id) do
    MatchCandidate
    |> where([c], c.media_file_id == ^media_file_id)
    |> order_by([c], asc: c.rank)
    |> Repo.all()
  end

  @doc """
  Deletes every cached candidate for a media file.

  Called once a file is linked, so the inbox query stops returning it.
  """
  @spec delete_match_candidates(binary()) :: {integer(), nil}
  def delete_match_candidates(media_file_id) do
    MatchCandidate
    |> where([c], c.media_file_id == ^media_file_id)
    |> Repo.delete_all()
  end

  ## Import Runs

  alias Mydia.Library.ImportRun

  @doc """
  Starts an import run for a library path.

  Returns an error changeset when the path already has a run in flight. The
  guarantee is enforced by a partial unique index, so two tabs pressing Start
  simultaneously cannot both win.
  """
  @spec create_import_run(map()) :: {:ok, ImportRun.t()} | {:error, Ecto.Changeset.t()}
  def create_import_run(attrs) do
    attrs
    |> ImportRun.create_changeset()
    |> Repo.insert()
  end

  @doc """
  Fetches an import run by id, or nil.
  """
  @spec get_import_run(binary()) :: ImportRun.t() | nil
  def get_import_run(id), do: Repo.get(ImportRun, id)

  @doc """
  Returns the in-flight run for a library path, or nil.

  A `:stopping` run counts as in flight: the coordinator is still draining its
  current chunk and a second run would race it.
  """
  @spec active_import_run(binary()) :: ImportRun.t() | nil
  def active_import_run(library_path_id) do
    statuses = ImportRun.active_statuses()

    ImportRun
    |> where([r], r.library_path_id == ^library_path_id and r.status in ^statuses)
    |> Repo.one()
  end

  @doc """
  Updates progress counters or lifecycle state on a run.
  """
  @spec update_import_run(ImportRun.t(), map()) ::
          {:ok, ImportRun.t()} | {:error, Ecto.Changeset.t()}
  def update_import_run(%ImportRun{} = run, attrs) do
    run
    |> ImportRun.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Asks a run to stop at the next chunk boundary.
  """
  @spec request_import_run_stop(ImportRun.t()) ::
          {:ok, ImportRun.t()} | {:error, Ecto.Changeset.t()}
  def request_import_run_stop(%ImportRun{} = run) do
    update_import_run(run, %{status: :stopping})
  end

  @doc """
  Re-reads a run and reports whether a stop has been requested.

  Re-reads rather than inspecting the passed struct because the coordinator
  holds a stale copy between chunks; the whole point is to observe a write made
  by another process.
  """
  @spec import_run_stopping?(ImportRun.t() | binary()) :: boolean()
  def import_run_stopping?(%ImportRun{id: id}), do: import_run_stopping?(id)

  def import_run_stopping?(id) when is_binary(id) do
    case Repo.get(ImportRun, id) do
      %ImportRun{status: :stopping} -> true
      _ -> false
    end
  end

  @doc """
  Returns `{media_file_id, absolute_path}` for files still needing a match.

  A file needs matching when it has no parent association and no cached
  candidate. Excluding files that already carry a candidate is what lets a
  resumed run skip relay work a previous run already paid for.
  """
  @spec list_unmatched_media_file_paths(binary(), pos_integer()) :: [{binary(), String.t()}]
  def list_unmatched_media_file_paths(library_path_id, limit) do
    MediaFile
    |> where([f], f.library_path_id == ^library_path_id)
    |> where([f], is_nil(f.media_item_id) and is_nil(f.episode_id))
    |> where([f], is_nil(f.trashed_at))
    |> join(:left, [f], c in MatchCandidate, on: c.media_file_id == f.id)
    |> where([_f, c], is_nil(c.id))
    |> limit(^limit)
    |> preload(:library_path)
    |> Repo.all()
    |> Enum.map(fn file -> {file.id, MediaFile.absolute_path(file)} end)
    |> Enum.reject(fn {_id, path} -> is_nil(path) end)
  end

  ## Import Inbox

  @low_confidence_ceiling 0.8

  @doc """
  Lists unresolved files with their cached match candidate.

  "Unresolved" means orphaned, untrashed, and carrying a candidate row at rank
  0 (the only rank the match phase writes today, see `file_ingest.ex`). This
  is the permanent inbox that replaced the old per-session review list: it is
  a live query, so approving a file removes it from these results with no
  session state to persist.

  ## Options

    * `:library_path_id` - restrict to one library
    * `:filter` - `:all` (default), `:unidentified`, or `:low_confidence`
    * `:limit` - default 100
    * `:offset` - default 0
  """
  @spec list_inbox_files(keyword()) :: [
          %{media_file: MediaFile.t(), candidate: MatchCandidate.t()}
        ]
  def list_inbox_files(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    rows =
      MediaFile
      |> maybe_scope_library(opts[:library_path_id])
      |> inbox_base_query()
      |> apply_inbox_filter(opts[:filter] || :all)
      |> order_by([f, c], asc_nulls_last: c.title, asc: f.relative_path)
      |> limit(^limit)
      |> offset(^offset)
      |> select([f, c], %{media_file: f, candidate: c})
      |> Repo.all()

    # Preloaded explicitly (rather than via a query-level `preload`) because
    # the query above already carries a custom `select` map; the two structs
    # in each row are re-associated by position after the batch preload,
    # which `Repo.preload/2` guarantees preserves list order.
    media_files =
      rows
      |> Enum.map(& &1.media_file)
      |> Repo.preload(:library_path)

    rows
    |> Enum.zip(media_files)
    |> Enum.map(fn {row, media_file} -> %{row | media_file: media_file} end)
  end

  @doc """
  Counts files awaiting review in the import inbox.

  A file becomes inbox work once it carries a match candidate (a real match or
  a recorded failed attempt) and still has no parent. This is the mirror image
  of `list_unmatched_media_file_paths/2`: unmatched excludes a candidate,
  inbox requires one.

  ## Options

    * `:library_path_id` - required, scopes the count to one library path
    * `:filter` - `:all` (default), `:unidentified`, or `:low_confidence`
  """
  @spec count_inbox_files(keyword()) :: non_neg_integer()
  def count_inbox_files(opts) do
    library_path_id = Keyword.fetch!(opts, :library_path_id)

    MediaFile
    |> where([f], f.library_path_id == ^library_path_id)
    |> inbox_base_query()
    |> apply_inbox_filter(opts[:filter] || :all)
    |> select([f, _c], count(f.id, :distinct))
    |> Repo.one()
  end

  # Shared by list_inbox_files/1 and count_inbox_files/1 so the two can never
  # drift on what "unresolved" means: orphaned, untrashed, and joined to its
  # rank-0 candidate (an inner join, so a file with no candidate at all drops
  # out entirely -- that set is list_unmatched_media_file_paths/2 instead).
  defp inbox_base_query(query) do
    query
    |> where([f], is_nil(f.media_item_id) and is_nil(f.episode_id))
    |> where([f], is_nil(f.trashed_at))
    |> join(:inner, [f], c in MatchCandidate, on: c.media_file_id == f.id and c.rank == 0)
  end

  defp maybe_scope_library(query, nil), do: query

  defp maybe_scope_library(query, library_path_id),
    do: where(query, [f], f.library_path_id == ^library_path_id)

  defp apply_inbox_filter(query, :all), do: query

  defp apply_inbox_filter(query, :unidentified),
    do: where(query, [_f, c], is_nil(c.provider_id))

  defp apply_inbox_filter(query, :low_confidence) do
    where(
      query,
      [_f, c],
      not is_nil(c.provider_id) and c.confidence < ^@low_confidence_ceiling
    )
  end
end
