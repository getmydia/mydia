defmodule Mydia.Library.MediaFiles do
  @moduledoc """
  Reads and writes of `Mydia.Library.MediaFile` rows: lookups, counts, creation, updates and extras filtering.
  """

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  require Logger
  alias Mydia.Repo
  alias Mydia.Library.{EpisodeLinks, MediaFile}

  @doc """
  Returns the total storage used by all media files in bytes.
  """
  @spec total_storage_bytes() :: non_neg_integer()
  def total_storage_bytes do
    MediaFile
    |> where([f], is_nil(f.trashed_at))
    |> select([f], sum(f.size))
    |> Repo.one()
    |> to_integer()
  end

  @doc """
  Returns the number of media files not in the trash.
  """
  @spec media_file_count() :: non_neg_integer()
  def media_file_count do
    MediaFile
    |> where([f], is_nil(f.trashed_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the list of media files.

  ## Options
    - `:media_item_id` - Filter by media item
    - `:episode_id` - Filter by episode
    - `:library_path_id` - Filter by library path ID
    - `:library_path_type` - Filter by library path type (e.g., :movies, :series)
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
  @spec list_media_ids_in_library_path(Mydia.Settings.LibraryPath.t()) :: [binary()]
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
  Returns every media file at a relative path, live files first.

  `get_media_file_by_relative_path/3` raises `Ecto.MultipleResultsError` when
  duplicate rows exist for one path, a state the database has reached before
  (a path imported by two builds of the scanner). Callers that only need to
  answer "does this file already exist" use this instead so a duplicate row is
  data to skip, not a crash.
  """
  @spec list_media_files_by_relative_path(binary(), String.t(), keyword()) :: [MediaFile.t()]
  def list_media_files_by_relative_path(library_path_id, relative_path, opts \\ []) do
    query =
      MediaFile
      |> where([f], f.library_path_id == ^library_path_id and f.relative_path == ^relative_path)

    query =
      if Keyword.get(opts, :include_trashed, false),
        do: query,
        else: where(query, [f], is_nil(f.trashed_at))

    query
    |> order_by([f], asc_nulls_first: f.trashed_at)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Returns true when the episode already has a media file that has not been trashed.

  Used by the importer to skip season-pack files for episodes the library
  already has, since nothing downstream reconciles two live files for one
  episode outside the upgrade path.

  Counts only real versions of the episode (`is_nil(extra_kind)`). A bonus
  file scanner-matched to this episode — a trailer, a deleted scene — must
  not make the importer believe the episode is already filled and skip the
  real file a season pack is trying to deliver. Getting this wrong here is
  invisible at the call site: the importer logs "episode already has a media
  file" as if it succeeded, while the real file is silently dropped.
  """
  @spec episode_has_media_file?(String.t()) :: boolean()
  def episode_has_media_file?(episode_id) when is_binary(episode_id) do
    Repo.exists?(
      from(f in MediaFile,
        where: f.episode_id == ^episode_id and is_nil(f.trashed_at) and is_nil(f.extra_kind)
      )
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
    |> tap_episode_link()
  end

  @doc """
  Attaches the import candidate `candidate_id` to an existing movie or
  episode. See `Mydia.Library.CandidatePromotion.attach/3`.
  """
  @spec attach_candidate(binary(), Mydia.Media.MediaItem.t() | Mydia.Media.Episode.t()) ::
          {:ok, MediaFile.t()} | {:error, term()}
  def attach_candidate(candidate_id, target) do
    with {:ok, _uuid} <- Ecto.UUID.cast(candidate_id),
         %Mydia.Library.ImportCandidate{} = candidate <-
           Repo.get(Mydia.Library.ImportCandidate, candidate_id) do
      Mydia.Library.CandidatePromotion.attach(candidate, target, [])
    else
      _missing -> {:error, {:candidate_missing, candidate_id}}
    end
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
    |> tap_episode_link()
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
    |> tap_episode_link()
  end

  @doc """
  Updates a media file during library scanning.

  Uses the scan-specific changeset so filesystem-derived fields can be
  refreshed without exposing ownership fields to the scanner.
  """
  @spec update_media_file_scan(MediaFile.t(), map()) ::
          {:ok, MediaFile.t()} | {:error, Ecto.Changeset.t()}
  def update_media_file_scan(%MediaFile{} = media_file, attrs) do
    media_file
    |> MediaFile.scan_changeset(attrs)
    |> Repo.update()
    |> tap_episode_link()
  end

  # Keeps media_file_episodes in step with whatever a write left in
  # `episode_id`. See `ensure_episode_link/1`.
  defp tap_episode_link({:ok, %MediaFile{} = media_file} = result) do
    {:ok, _} = EpisodeLinks.ensure_episode_link(media_file)
    result
  end

  defp tap_episode_link(other), do: other

  @doc """
  Marks a media file as verified.
  """
  @spec verify_media_file(MediaFile.t()) :: {:ok, MediaFile.t()} | {:error, Ecto.Changeset.t()}
  def verify_media_file(%MediaFile{} = media_file) do
    media_file
    |> Ecto.Changeset.change(verified_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  # `sum/1` returns an integer on SQLite and a `Decimal` on PostgreSQL, and
  # every byte figure on the trash page goes through arithmetic that raises on
  # a Decimal, so the page 500s on Postgres without this.
  #
  # Casting in SQL with `type(sum(f.size), :integer)` looks tidier and is
  # wrong: Postgres `integer` is 4 bytes, so it raises "integer out of range"
  # above 2.1 GB, which every real library passes. Elixir integers have no
  # such ceiling.
  @doc false
  def to_integer(nil), do: 0
  def to_integer(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  def to_integer(bytes) when is_integer(bytes), do: bytes

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking media file changes.
  """
  @spec change_media_file(MediaFile.t(), map()) :: Ecto.Changeset.t()
  def change_media_file(%MediaFile{} = media_file, attrs \\ %{}) do
    MediaFile.changeset(media_file, attrs)
  end

  @doc """
  Gets a media item's files.

  Extras are excluded by default, so callers that ask "which files does this
  movie have" get versions of the movie. Pass `include_extras: true` for the
  file list on the movie page, which shows both.

  The default is right for an OWNERSHIP question — "which file is this
  movie", "does this item have files". It is wrong for INVENTORY or
  RECONCILIATION — "what rows already exist", "which rows are missing from
  disk". An inventory caller that gets the filtered set treats an
  already-persisted extra as absent, so a rescan re-inserts it forever (no
  unique index on `path` catches the duplicate), and a missing-file sweep
  never reaps a deleted extra. Inventory and reconciliation callers must pass
  `include_extras: true`.
  """
  @spec get_media_files_for_item(binary(), keyword()) :: [MediaFile.t()]
  def get_media_files_for_item(media_item_id, opts \\ []) do
    {include_extras, opts} = Keyword.pop(opts, :include_extras, false)

    [media_item_id: media_item_id]
    |> Kernel.++(opts)
    |> list_media_files()
    |> reject_extras(include_extras)
  end

  @doc """
  Gets all media files for an episode.

  Extras are excluded by default, mirroring `get_media_files_for_item/2`. Pass
  `include_extras: true` to get both.

  Same inventory-versus-ownership rule as `get_media_files_for_item/2`: the
  default suits "does this episode have a file" callers, not "what rows
  already exist on disk for this episode" callers. See that function's doc
  for why getting this wrong is a data-integrity bug, not just a display one.
  """
  @spec get_media_files_for_episode(binary(), keyword()) :: [MediaFile.t()]
  def get_media_files_for_episode(episode_id, opts \\ []) do
    {include_extras, opts} = Keyword.pop(opts, :include_extras, false)

    [episode_id: episode_id]
    |> Kernel.++(opts)
    |> list_media_files()
    |> reject_extras(include_extras)
  end

  defp reject_extras(files, true), do: files
  defp reject_extras(files, false), do: Enum.filter(files, &is_nil(&1.extra_kind))

  @doc """
  Rows that could be the old record of a file that turned up somewhere new:
  any row already trashed because its file went missing, plus active rows in
  other library paths. Callers must still confirm an active row's file is gone
  before relinking it. Filtered by size, so the result is small.
  """
  @relink_candidate_chunk 1000

  @spec list_relink_candidates([non_neg_integer()], binary()) :: [MediaFile.t()]
  def list_relink_candidates([], _library_path_id), do: []

  def list_relink_candidates(sizes, library_path_id) do
    # One bind parameter per size: a first scan of a large library can carry
    # tens of thousands, past SQLite's 32766-variable limit. Chunk the lookup.
    sizes
    |> Enum.uniq()
    |> Enum.chunk_every(@relink_candidate_chunk)
    |> Enum.flat_map(&relink_candidates_chunk(&1, library_path_id))
  end

  defp relink_candidates_chunk(sizes, library_path_id) do
    MediaFile
    |> where([f], f.size in ^sizes)
    |> where(
      [f],
      (not is_nil(f.trashed_at) and f.trashed_reason == :missing) or
        (is_nil(f.trashed_at) and f.library_path_id != ^library_path_id)
    )
    |> preload(:library_path)
    |> Repo.all()
  end

  # Calculates the relative path and library_path_id for an absolute file path
  # Returns {library_path_id, relative_path}
  @doc false
  def calculate_relative_path(absolute_path, library_paths) do
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
        # Filter files by their library path type (e.g., :movies, :series)
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
end
