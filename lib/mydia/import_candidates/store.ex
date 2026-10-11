defmodule Mydia.ImportCandidates.Store do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Mydia.ImportCandidates.Review
  alias Mydia.Library.{ImportCandidate, MediaFile, PathAnchor, ReleaseParser}
  alias Mydia.Media
  alias Mydia.Media.Episode
  alias Mydia.Repo
  alias Mydia.Settings.LibraryPath

  # Page size `delete_missing/3` walks the library path's candidates in.
  # `relative_path not in ^relative_paths` would put one bind parameter per
  # on-disk path into a single query -- a library with tens of thousands of
  # files would exceed SQLite's SQLITE_MAX_VARIABLE_NUMBER (32766 on current
  # builds, 999 on older ones) and PostgreSQL's 65535 parameter ceiling.
  # Instead, `relative_paths` is turned into an in-memory `MapSet` once and
  # each page's candidates are matched against it in Elixir; only the
  # resulting missing-id delete is a bind list, and it never exceeds this
  # page size regardless of how large the library is.
  @delete_missing_batch_size 500

  @spec upsert(map() | keyword()) :: {:ok, ImportCandidate.t()} | {:error, Ecto.Changeset.t()}
  def upsert(attrs) do
    attrs = Map.new(attrs)
    library_path_id = Map.fetch!(attrs, :library_path_id)
    relative_path = Map.fetch!(attrs, :relative_path)

    case Repo.get_by(ImportCandidate,
           library_path_id: library_path_id,
           relative_path: relative_path
         ) do
      nil -> insert_or_update(%ImportCandidate{}, attrs, library_path_id, relative_path)
      existing -> insert_or_update(existing, attrs, library_path_id, relative_path)
    end
  end

  @spec get_by_path(binary(), String.t()) :: ImportCandidate.t() | nil
  def get_by_path(library_path_id, relative_path) do
    Repo.get_by(ImportCandidate, library_path_id: library_path_id, relative_path: relative_path)
  end

  @doc """
  Detaches a media file the matcher filed against the wrong item and returns it
  to the review inbox.

  The row goes and the bytes stay. A candidate is written at the file's current
  `(library_path_id, relative_path)` so `/review` can match it against the right
  item, with three fields set so the correction sticks:

    * `returned_at`, which holds it out of unattended promotion
      (`Mydia.Library.FileIngest`) and, here, out of the ready band and
      `AcceptQueue.queue_accept_all_matched/1`, so only a person can put it back;
    * `queued_op: "rematch"`, so `Mydia.Jobs.RematchImportCandidates` gives it
      a fresh suggestion under the `:review` policy, which never promotes.
      The job is enqueued inside the same transaction as the detach, so a
      failed enqueue rolls the whole detach back rather than leaving the
      candidate queued with nothing to drain it;
    * `dismissed_at: nil`, because a dismissed candidate already at that path
      would otherwise hide the file from the inbox it was just sent to.

  The owning item comes from the file itself (the movie for a movie file, the
  show for an episode file) and supplies the candidate's `media_type`. Without
  it `ImportCandidate.parsed_info/1` defaults a nil type to movie, so a
  returned episode would be matched as a film.

  A legacy row carrying only `path` has no `(library_path_id, relative_path)`
  pair to key a candidate by, and returns `{:error, :no_library_path}`.
  """
  @spec return_to_review(MediaFile.t(), String.t()) ::
          {:ok, MediaFile.t()} | {:error, :no_library_path} | {:error, term()}
  def return_to_review(%MediaFile{} = file, actor_id) when is_binary(actor_id) do
    file = Repo.preload(file, [:library_path, :media_item, episode: :media_item])

    case {file.library_path, file.relative_path, owning_item(file)} do
      {%LibraryPath{} = library_path, relative_path, %Media.MediaItem{} = media_item}
      when is_binary(relative_path) ->
        detach_to_review(file, library_path, media_item, actor_id)

      _ ->
        {:error, :no_library_path}
    end
  end

  defp owning_item(%MediaFile{episode: %Episode{media_item: %Media.MediaItem{} = item}}),
    do: item

  defp owning_item(%MediaFile{media_item: %Media.MediaItem{} = item}), do: item
  defp owning_item(%MediaFile{}), do: nil

  defp detach_to_review(file, library_path, media_item, actor_id) do
    now = now()

    anchor =
      PathAnchor.anchor_for(Path.join(library_path.path, file.relative_path), library_path.path)

    attrs = %{
      library_path_id: library_path.id,
      relative_path: file.relative_path,
      anchor_key: anchor.cluster_key,
      size: file.size,
      media_type: media_item.type,
      discovered_at: now,
      returned_at: now,
      dismissed_at: nil,
      queued_op: "rematch",
      queued_at: now,
      queue_error: nil
    }

    # All three -- the candidate appearing, the media_files row disappearing,
    # and the rematch job -- must succeed or fail together. Two independent
    # Repo calls would let a hard interruption between them leave the file
    # both still attached to the wrong item and duplicated into
    # import_candidates; enqueueing outside the transaction would let a job
    # insert failure leave the candidate queued with nothing left to drain it.
    #
    # The activity event is recorded inside the same transaction on purpose:
    # Mydia.Repo.transaction/2 defers its PubSub broadcast until the outermost
    # transaction commits and discards it on rollback, so the feed never
    # reports something that did not happen.
    result =
      Repo.transaction(fn ->
        with {:ok, _candidate} <- upsert(attrs),
             {:ok, deleted} <- Mydia.Library.delete_media_file(file, delete_files: false),
             {:ok, _job} <- enqueue(Mydia.Jobs.RematchImportCandidates, library_path.id) do
          Mydia.Events.file_returned_to_review(deleted, media_item, actor_id)
          deleted
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, _deleted} ->
        broadcast(library_path.id)
        result

      {:error, _reason} ->
        result
    end
  end

  @doc """
  Reaps candidates for `library_path_id` whose `relative_path` is absent from
  `relative_paths` (the paths a scan just found on disk).

  Refuses to run when `relative_paths` is empty: `not in ^[]` is true for
  every row, so an empty list is indistinguishable in SQL from "everything is
  gone". An empty scan result is far more often a scan that saw nothing (an
  unmounted network share, a library type whose extension filter matched zero
  files) than a library that has genuinely been emptied, and a stale
  candidate left behind is recoverable while a deleted one is not -- so this
  treats an empty scan as non-authoritative and does nothing, logging a
  warning since a silently skipped reap is the kind of thing an operator
  needs to see. This guard lives here, not only at the scanner call site, so
  no future caller can bypass it by forgetting to check first.

  Walks the library path's candidates in bounded pages (`:batch_size` option,
  default `#{@delete_missing_batch_size}`) rather than sending
  `relative_paths` to the database as bind parameters: see
  `@delete_missing_batch_size` for why.
  """
  @spec delete_missing(binary(), [String.t()], keyword()) ::
          {non_neg_integer(), nil | [term()]}
  def delete_missing(library_path_id, relative_paths, opts \\ [])

  def delete_missing(library_path_id, [], _opts) do
    Logger.warning(
      "Refusing to reap import candidates: scan reported zero on-disk files",
      library_path_id: library_path_id
    )

    {0, nil}
  end

  def delete_missing(library_path_id, relative_paths, opts) do
    batch_size = Keyword.get(opts, :batch_size, @delete_missing_batch_size)
    on_disk = MapSet.new(relative_paths)

    {delete_missing_pages(library_path_id, on_disk, batch_size, nil, 0), nil}
  end

  defp delete_missing_pages(library_path_id, on_disk, batch_size, after_id, deleted) do
    page =
      ImportCandidate
      |> where([c], c.library_path_id == ^library_path_id)
      |> Review.maybe_after_id(after_id)
      |> order_by([c], asc: c.id)
      |> select([c], {c.id, c.relative_path})
      |> limit(^batch_size)
      |> Repo.all()

    case page do
      [] ->
        deleted

      page ->
        missing_ids =
          for {id, relative_path} <- page, not MapSet.member?(on_disk, relative_path), do: id

        deleted = deleted + delete_batch(missing_ids)

        if length(page) < batch_size do
          deleted
        else
          {last_id, _relative_path} = List.last(page)
          delete_missing_pages(library_path_id, on_disk, batch_size, last_id, deleted)
        end
    end
  end

  defp delete_batch([]), do: 0

  defp delete_batch(ids) do
    {count, _} = ImportCandidate |> where([c], c.id in ^ids) |> Repo.delete_all()
    count
  end

  @doc """
  Moves an episode's files into `import_candidates`, deleting their
  `media_files` rows and keeping the bytes on disk.

  `dismiss: true` parks the candidates as dismissed. Removal from the library
  uses it so no scan or bulk accept re-imports what the user removed. Deleting
  an episode or switching provider keeps the default, because those files are
  still wanted, only their parent changed.
  """
  @spec demote_episode_files(Episode.t(), keyword()) :: {:ok, :ok} | {:error, term()}
  def demote_episode_files(%Episode{} = episode, opts \\ []) do
    dismissal = dismissal_attrs(opts)

    Repo.transaction(fn ->
      episode = Repo.preload(episode, [:media_item, media_files: :library_path])

      Enum.each(episode.media_files, fn file ->
        attrs =
          Map.merge(dismissal, %{
            relative_path: file.relative_path,
            size: file.size,
            discovered_at: file.inserted_at,
            parsed_info: %{
              "season" => episode.season_number,
              "episodes" => [episode.episode_number]
            }
          })

        case stage_item_file(episode.media_item, file.library_path, attrs) do
          {:ok, _candidate} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end

        Repo.delete!(file)
      end)

      :ok
    end)
  end

  @doc """
  Moves a movie's live files into `import_candidates` and deletes their rows.

  Trashed rows are skipped: their files already left disk, so a candidate
  would point at nothing. Rows with no library path or relative path predate
  path-keyed storage and cannot be addressed as a candidate; they are left for
  the item's cascade delete. `dismiss:` behaves as in `demote_episode_files/2`.
  """
  @spec demote_movie_files(Media.MediaItem.t(), keyword()) :: {:ok, :ok} | {:error, term()}
  def demote_movie_files(%Media.MediaItem{} = movie, opts \\ []) do
    dismissal = dismissal_attrs(opts)

    Repo.transaction(fn ->
      MediaFile
      |> where(
        [f],
        f.media_item_id == ^movie.id and is_nil(f.trashed_at) and
          not is_nil(f.library_path_id) and not is_nil(f.relative_path)
      )
      |> preload(:library_path)
      |> Repo.all()
      |> Enum.each(fn file ->
        attrs =
          Map.merge(dismissal, %{
            relative_path: file.relative_path,
            size: file.size,
            discovered_at: file.inserted_at
          })

        case stage_item_file(movie, file.library_path, attrs) do
          {:ok, _candidate} -> Repo.delete!(file)
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

      :ok
    end)
  end

  @doc """
  Stages a file under `item`'s provider identity, title and year.

  `media_type` follows the item's type. For a show this is where a TV file
  that belongs to none of its episodes goes: a TV file is never a
  `media_files` row attached to the show itself
  (the `Mydia.Library.MediaFile` changeset refuses that shape). The title and
  year matter: without them the review row has a provider id and nothing to
  name it by.

  `attrs` needs `:relative_path`, `:size` and `:discovered_at`. `:parsed_info`
  (string keys) is optional and is derived from the filename when absent.
  `:dismissed_at` is optional and parks the candidate as dismissed.
  """
  @spec stage_item_file(Media.MediaItem.t(), LibraryPath.t(), map()) ::
          {:ok, ImportCandidate.t()} | {:error, Ecto.Changeset.t()}
  def stage_item_file(%Media.MediaItem{} = item, %LibraryPath{} = library_path, attrs) do
    relative_path = Map.fetch!(attrs, :relative_path)

    anchor =
      PathAnchor.anchor_for(Path.join(library_path.path, relative_path), library_path.path)

    {provider_type, provider_id} = provider_identity(item)

    parsed_info =
      attrs
      |> Map.get_lazy(:parsed_info, fn -> filename_parsed_info(relative_path) end)
      |> Map.put("type", item.type)

    # dismissed_at is passed only when the caller supplied one. Upsert casts
    # whatever keys it is given, so a nil here would un-dismiss a parked
    # candidate already at this path.
    %{
      library_path_id: library_path.id,
      relative_path: relative_path,
      anchor_key: anchor.cluster_key,
      size: Map.fetch!(attrs, :size),
      discovered_at: Map.fetch!(attrs, :discovered_at),
      provider_type: provider_type,
      provider_id: provider_id,
      title: item.title,
      year: item.year,
      media_type: item.type,
      parsed_info: parsed_info
    }
    |> Map.merge(Map.take(attrs, [:dismissed_at]) |> Map.reject(fn {_k, v} -> is_nil(v) end))
    |> upsert()
  end

  defp dismissal_attrs(opts) do
    if Keyword.get(opts, :dismiss, false), do: %{dismissed_at: now()}, else: %{}
  end

  defp filename_parsed_info(relative_path) do
    parsed = ReleaseParser.parse(Path.basename(relative_path))
    %{"season" => parsed.season, "episodes" => parsed.episodes || []}
  end

  # `states:` is overridden here rather than declared on `use Oban.Worker` in
  # the worker modules themselves, so it deliberately excludes `:executing`: a
  # click landing while a drain is already running must enqueue a fresh job
  # rather than be swallowed by the uniqueness guard (see both workers'
  # moduledocs). Declaring that narrowed list statically trips Oban's own
  # `--warnings-as-errors` compile check (it warns whenever `:states` omits
  # any incomplete state); overriding it only here, at the single call site
  # both workers share, avoids the warning the same way
  # `Jobs.MediaImport.Failure.schedule_snooze_retry/3` does for its own narrowed case.
  @doc false
  def enqueue(worker, library_path_id) do
    %{"library_path_id" => library_path_id}
    |> worker.new(unique: [states: [:available, :scheduled, :retryable]])
    |> Mydia.Jobs.insert()
  end

  @doc false
  def broadcast(library_path_id) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "import_candidates:#{library_path_id}",
      {:import_candidates_changed, library_path_id}
    )
  end

  # `DateTime.truncate(:second)` matters here, not just cosmetically: every
  # caller stores this into a `:utc_datetime` column, which cannot hold
  # microseconds, and Ecto would otherwise raise a cast error on insert.
  @doc false
  def now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # --- internal helpers ----------------------------------------------------

  defp insert_or_update(candidate, attrs, library_path_id, relative_path) do
    case candidate |> ImportCandidate.changeset(attrs) |> Repo.insert_or_update() do
      {:error, %Ecto.Changeset{} = changeset} ->
        case Repo.get_by(ImportCandidate,
               library_path_id: library_path_id,
               relative_path: relative_path
             ) do
          nil -> {:error, changeset}
          existing -> existing |> ImportCandidate.changeset(attrs) |> Repo.update()
        end

      result ->
        result
    end
  end

  @doc false
  @spec provider_identity(map()) :: {String.t() | nil, String.t() | nil}
  def provider_identity(%{metadata_source: :tmdb, tmdb_id: id}) when not is_nil(id),
    do: {"tmdb", Integer.to_string(id)}

  def provider_identity(%{metadata_source: :tvdb, tvdb_id: id}) when not is_nil(id),
    do: {"tvdb", Integer.to_string(id)}

  def provider_identity(%{metadata_source: :tmdb}), do: {"tmdb", nil}
  def provider_identity(%{metadata_source: :tvdb}), do: {"tvdb", nil}

  def provider_identity(%{tvdb_id: id}) when not is_nil(id), do: {"tvdb", Integer.to_string(id)}
  def provider_identity(%{tmdb_id: id}) when not is_nil(id), do: {"tmdb", Integer.to_string(id)}
  def provider_identity(_), do: {nil, nil}
end
