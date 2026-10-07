defmodule Mydia.Library.CandidatePromotion do
  @moduledoc "Promotes one durable import-candidate group into owned media files."

  import Ecto.Query

  alias Mydia.Accounts.Scope
  alias Mydia.{DB, Metadata, Repo}
  alias Mydia.Library.{EpisodeMinter, ImportCandidate, MediaFile, MetadataEnricher}
  alias Mydia.Media
  alias Mydia.Settings.LibraryPath
  alias Mydia.Storage
  alias Mydia.Subtitles.Sidecars

  @spec promote_group([ImportCandidate.t()], map(), keyword()) ::
          {:ok, [MediaFile.t()]} | {:error, term()}
  def promote_group([%ImportCandidate{} | _] = candidates, match, opts) do
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()
    candidates = Enum.sort_by(candidates, & &1.id)
    snapshot = candidate_snapshot(candidates)

    with :ok <- one_group?(candidates),
         {:ok, preparation} <- MetadataEnricher.prepare(match, config: config),
         {:ok, {media_files, media_item}} <-
           commit_group(candidates, snapshot, preparation, opts) do
      MetadataEnricher.finalize(media_item)
      Sidecars.reconcile_all(Repo.preload(media_files, :library_path))
      {:ok, media_files}
    end
  end

  def promote_group([], _match, _opts), do: {:error, :empty_group}

  @doc """
  Attaches one candidate to an item that already exists: a movie
  `%MediaItem{}` or an `%Episode{}` with `:media_item` preloaded.

  Unlike `promote_group/3` there is no metadata step, because the target is
  already in the library. It shares the same locking and file-insert path, so
  it cannot race a promotion of the same candidate. A dismissed candidate is
  fine: parked files are exactly what this is for. A candidate with a queued
  operation is refused, since that operation already decided its fate.

  For an episode, a file whose parsed episodes span several episodes of the
  target's season (and include the target) is linked to each one that exists.
  None are minted.
  """
  @spec attach(ImportCandidate.t(), Media.MediaItem.t() | Media.Episode.t(), keyword()) ::
          {:ok, MediaFile.t()} | {:error, term()}
  def attach(%ImportCandidate{} = candidate, target, opts) do
    with {:ok, parent} <- attach_parent(target),
         {:ok, media_file} <- commit_attach(candidate, target, parent, opts) do
      MetadataEnricher.finalize(attach_media_item(target))
      Sidecars.reconcile_all(Repo.preload([media_file], :library_path))
      {:ok, media_file}
    else
      {:error, :file_missing} ->
        drop_unqueued(candidate)
        {:error, :file_missing}

      {:error, {:duplicate_path, _, _} = reason} ->
        drop_unqueued(candidate)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The row may already be gone and a queued operation owns its fate, so this
  # is a guarded bulk delete rather than Repo.delete on a possibly stale struct.
  defp drop_unqueued(%ImportCandidate{id: id}) do
    ImportCandidate
    |> where([c], c.id == ^id and is_nil(c.queued_op))
    |> Repo.delete_all()
  end

  defp on_disk(%ImportCandidate{library_path: nil} = candidate),
    do: {:error, {:library_path_missing, candidate.library_path_id}}

  defp on_disk(%ImportCandidate{library_path: library_path} = candidate) do
    cond do
      # Checked before the transaction by `preflight_object/1`: a slow or dead
      # backend must not hold SQLite's write lock.
      Storage.s3?(library_path) ->
        :ok

      File.exists?(ImportCandidate.absolute_path(candidate)) ->
        :ok

      true ->
        {:error, :file_missing}
    end
  end

  defp preflight_object(%ImportCandidate{} = candidate) do
    case Repo.preload(candidate, :library_path) do
      %ImportCandidate{library_path: %LibraryPath{} = library_path} = loaded ->
        if Storage.s3?(library_path),
          do: object_present(library_path, loaded.relative_path),
          else: :ok

      _ ->
        :ok
    end
  end

  # Only a definite "not found" is a missing file. An unreachable or refusing
  # backend says nothing about the object, so it must not drop the candidate.
  defp object_present(library_path, relative_path) do
    with {:ok, location} <- Storage.location(library_path),
         {:ok, source} <- Storage.source(location, relative_path),
         {:ok, _entry} <- Storage.stat(source) do
      :ok
    else
      {:error, %Storage.Error{kind: :not_found}} -> {:error, :file_missing}
      {:error, %Storage.Error{} = error} -> {:error, {:storage, error}}
    end
  end

  defp attach_parent(%Media.MediaItem{type: "movie"} = movie),
    do: {:ok, %{media_item_id: movie.id}}

  defp attach_parent(%Media.Episode{media_item: %Media.MediaItem{}} = episode),
    do: {:ok, %{episode_id: episode.id}}

  defp attach_parent(target), do: {:error, {:incompatible_target, target}}

  defp sibling_episode_ids(_candidate, %Media.MediaItem{}), do: []

  defp sibling_episode_ids(%ImportCandidate{parsed_info: parsed_info}, %Media.Episode{} = episode) do
    parsed_info = parsed_info || %{}
    numbers = Map.get(parsed_info, "episodes") || []

    if Map.get(parsed_info, "season") == episode.season_number and
         episode.episode_number in numbers and length(numbers) > 1 do
      Media.Episode
      |> where(
        [e],
        e.media_item_id == ^episode.media_item_id and e.season_number == ^episode.season_number and
          e.episode_number in ^numbers and e.id != ^episode.id
      )
      |> select([e], e.id)
      |> Repo.all()
    else
      []
    end
  end

  defp attach_media_item(%Media.MediaItem{} = movie), do: movie
  defp attach_media_item(%Media.Episode{media_item: %Media.MediaItem{} = show}), do: show

  defp commit_attach(candidate, target, parent, opts) do
    transaction_opts = if DB.sqlite?(), do: [mode: :immediate], else: []

    ownership_attempt(opts)

    with :ok <- preflight_object(candidate) do
      attach_transaction(candidate, target, parent, opts, transaction_opts)
    end
  end

  defp attach_transaction(candidate, target, parent, opts, transaction_opts) do
    Repo.transaction(
      fn ->
        ownership_boundary(opts)

        with :ok <- lock_group([candidate]),
             {:ok, [reread]} <- reread_candidates([candidate]),
             locked = Repo.preload(reread, :library_path),
             :ok <- not_queued(locked),
             :ok <- compatible_media_type(locked, target),
             :ok <- on_disk(locked),
             :ok <- ensure_path_available(locked),
             {:ok, media_file} <- insert_file(locked, parent),
             {:ok, _} <- link_extra_episodes(media_file, sibling_episode_ids(locked, target)),
             :ok <- delete_candidates([locked]) do
          media_file
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      transaction_opts
    )
  end

  # Same rule promote_group applies through resolve_parent: a candidate
  # classified as one kind never attaches to an item of the other.
  defp compatible_media_type(%ImportCandidate{media_type: nil}, _target), do: :ok

  defp compatible_media_type(%ImportCandidate{media_type: type}, target) do
    if type == expected_media_type(target),
      do: :ok,
      else: {:error, {:incompatible_media_type, type}}
  end

  defp expected_media_type(%Media.MediaItem{type: "movie"}), do: "movie"
  defp expected_media_type(%Media.Episode{}), do: "tv_show"

  defp not_queued(%ImportCandidate{queued_op: nil}), do: :ok
  defp not_queued(_candidate), do: {:error, :queued}

  defp link_extra_episodes(_media_file, []), do: {:ok, :none}

  defp link_extra_episodes(media_file, episode_ids),
    do: Mydia.Library.add_episode_links(media_file, episode_ids)

  defp commit_group(candidates, snapshot, preparation, opts) do
    transaction_opts = if DB.sqlite?(), do: [mode: :immediate], else: []

    ownership_attempt(opts)

    Repo.transaction(
      fn ->
        ownership_boundary(opts)

        with :ok <- lock_group(candidates),
             {:ok, locked_candidates} <- reread_candidates(candidates),
             :ok <- snapshot_matches?(locked_candidates, snapshot),
             :ok <- one_group?(locked_candidates),
             {:ok, media_item} <- MetadataEnricher.persist(preparation),
             {:ok, media_files} <- insert_files(locked_candidates, media_item, opts),
             :ok <- delete_candidates(locked_candidates) do
          {media_files, media_item}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      transaction_opts
    )
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # These optional hooks keep deterministic transaction-boundary
  # synchronization local to tests rather than introducing a callback registry.
  defp ownership_attempt(opts), do: ownership_hook(opts, :ownership_attempt)

  defp ownership_boundary(opts), do: ownership_hook(opts, :ownership_boundary)

  defp ownership_hook(opts, name) do
    case Keyword.get(opts, name) do
      callback when is_function(callback, 0) -> callback.()
      _ -> :ok
    end
  end

  # PostgreSQL serializes every promotion for a library on its library row,
  # then takes candidate row locks in ID order. SQLite uses BEGIN IMMEDIATE,
  # acquiring its single writer lock before any snapshot read.
  defp lock_group([%ImportCandidate{library_path_id: library_path_id} | _] = candidates) do
    if DB.postgres?() do
      case Repo.one(
             from library_path in LibraryPath,
               where: library_path.id == ^library_path_id,
               lock: "FOR UPDATE"
           ) do
        nil -> {:error, {:library_path_missing, library_path_id}}
        _library_path -> lock_candidates(candidates)
      end
    else
      :ok
    end
  end

  defp lock_candidates(candidates) do
    ids = Enum.map(candidates, & &1.id)

    locked_ids =
      ImportCandidate
      |> where([candidate], candidate.id in ^ids)
      |> order_by([candidate], asc: candidate.id)
      |> lock("FOR UPDATE")
      |> select([candidate], candidate.id)
      |> Repo.all()

    missing = ids -- locked_ids

    cond do
      missing != [] -> {:error, {:candidate_missing, hd(missing)}}
      length(locked_ids) == length(ids) -> :ok
      true -> {:error, {:candidate_missing, hd(ids)}}
    end
  end

  defp reread_candidates(candidates) do
    candidates
    |> Enum.reduce_while({:ok, []}, fn candidate, {:ok, acc} ->
      case Repo.get(ImportCandidate, candidate.id) do
        nil -> {:halt, {:error, {:candidate_missing, candidate.id}}}
        current -> {:cont, {:ok, [current | acc]}}
      end
    end)
    |> case do
      {:ok, locked} -> {:ok, Enum.reverse(locked)}
      error -> error
    end
  end

  defp candidate_snapshot(candidates) do
    Map.new(candidates, fn candidate -> {candidate.id, snapshot_fields(candidate)} end)
  end

  defp snapshot_matches?(candidates, snapshot) do
    case Enum.find(candidates, fn candidate ->
           Map.get(snapshot, candidate.id) != snapshot_fields(candidate)
         end) do
      nil -> :ok
      candidate -> {:error, {:stale_candidate, candidate.id}}
    end
  end

  defp snapshot_fields(candidate) do
    Map.take(candidate, [
      :id,
      :library_path_id,
      :relative_path,
      :anchor_key,
      :size,
      :mtime,
      :parsed_info,
      :provider_type,
      :provider_id,
      :title,
      :year,
      :media_type,
      :confidence,
      :attempts,
      :last_error,
      :next_retry_at,
      :dismissed_at,
      :discovered_at,
      :updated_at
    ])
  end

  defp insert_files(candidates, media_item, opts) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      with :ok <- ensure_path_available(candidate),
           {:ok, parent} <- resolve_parent(candidate, media_item, opts),
           {:ok, media_file} <- insert_file(candidate, parent) do
        {:cont, {:ok, [media_file | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, media_files} -> {:ok, Enum.reverse(media_files)}
      error -> error
    end
  end

  defp ensure_path_available(candidate) do
    if Repo.exists?(
         from file in MediaFile,
           where:
             file.library_path_id == ^candidate.library_path_id and
               file.relative_path == ^candidate.relative_path
       ) do
      {:error, {:duplicate_path, candidate.library_path_id, candidate.relative_path}}
    else
      :ok
    end
  end

  defp resolve_parent(%ImportCandidate{} = candidate, %{type: "movie"} = item, _opts)
       when candidate.media_type == "movie" do
    {:ok, %{media_item_id: item.id}}
  end

  defp resolve_parent(%ImportCandidate{} = candidate, %{type: "tv_show"} = item, opts)
       when candidate.media_type == "tv_show" do
    with {:ok, season, episode_number} <- target_episode(candidate),
         {:ok, episode} <- find_or_mint_episode(item, season, episode_number, candidate, opts) do
      {:ok, %{episode_id: episode.id}}
    end
  end

  defp resolve_parent(%ImportCandidate{} = candidate, item, _opts) do
    {:error, {:incompatible_media_type, candidate.media_type, item.type}}
  end

  defp target_episode(%ImportCandidate{parsed_info: parsed_info}) do
    parsed_info = parsed_info || %{}

    case {Map.get(parsed_info, "season"), Map.get(parsed_info, "episodes", [])} do
      {season, [episode_number]} when is_integer(season) and is_integer(episode_number) ->
        {:ok, season, episode_number}

      _ ->
        {:error, :unresolved_episode}
    end
  end

  defp find_or_mint_episode(item, season, episode_number, candidate, opts) do
    case Media.get_episode_by_number(Scope.system(), item.id, season, episode_number) do
      nil ->
        if Keyword.get(opts, :allow_episode_creation, false) do
          EpisodeMinter.mint(item, season, episode_number, Path.basename(candidate.relative_path))
        else
          {:error, :unresolved_episode}
        end

      episode ->
        {:ok, episode}
    end
  end

  defp insert_file(candidate, parent) do
    attrs =
      Map.merge(parent, %{
        library_path_id: candidate.library_path_id,
        relative_path: candidate.relative_path,
        size: candidate.size,
        verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    case %MediaFile{} |> MediaFile.changeset(attrs) |> Repo.insert() do
      {:ok, media_file} ->
        # Episode.media_files reads through media_file_episodes, so a bare
        # episode_id would leave the file invisible on the episode page.
        {:ok, _} = Mydia.Library.ensure_episode_link(media_file)
        {:ok, media_file}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp delete_candidates(candidates) do
    Enum.reduce_while(candidates, :ok, fn candidate, :ok ->
      case Repo.delete(candidate) do
        {:ok, _candidate} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  defp one_group?([%ImportCandidate{} = first | rest]) do
    if Enum.all?(rest, fn candidate ->
         candidate.library_path_id == first.library_path_id and
           candidate.anchor_key == first.anchor_key
       end) do
      :ok
    else
      {:error, :mixed_group}
    end
  end

  defp one_group?([]), do: {:error, :empty_group}
end
