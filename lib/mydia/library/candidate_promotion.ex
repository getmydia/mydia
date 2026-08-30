defmodule Mydia.Library.CandidatePromotion do
  @moduledoc "Promotes one durable import-candidate group into owned media files."

  import Ecto.Query

  alias Mydia.{DB, Metadata, Repo}
  alias Mydia.Library.{EpisodeMinter, ImportCandidate, MediaFile, MetadataEnricher}
  alias Mydia.Media
  alias Mydia.Settings.LibraryPath
  alias Mydia.Subtitles.Sidecars

  @spec promote_group([ImportCandidate.t()], map(), keyword()) ::
          {:ok, [MediaFile.t()]} | {:error, term()}
  def promote_group([%ImportCandidate{} | _] = candidates, match, opts) do
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()
    candidates = Enum.sort_by(candidates, & &1.id)
    snapshot = candidate_snapshot(candidates)

    with :ok <- one_group?(candidates),
         {:ok, media_item} <- MetadataEnricher.enrich(match, config: config),
         {:ok, media_files} <- commit_group(candidates, snapshot, media_item, opts) do
      Sidecars.reconcile_all(Repo.preload(media_files, :library_path))
      {:ok, media_files}
    end
  end

  def promote_group([], _match, _opts), do: {:error, :empty_group}

  defp commit_group(candidates, snapshot, media_item, opts) do
    transaction_opts = if DB.sqlite?(), do: [mode: :immediate], else: []

    ownership_attempt(opts)

    Repo.transaction(
      fn ->
        ownership_boundary(opts)

        with :ok <- lock_group(candidates),
             {:ok, locked_candidates} <- reread_candidates(candidates),
             :ok <- snapshot_matches?(locked_candidates, snapshot),
             :ok <- one_group?(locked_candidates),
             {:ok, media_files} <- insert_files(locked_candidates, media_item, opts),
             :ok <- delete_candidates(locked_candidates) do
          media_files
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      transaction_opts
    )
    |> case do
      {:ok, media_files} -> {:ok, media_files}
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

    if locked_ids == ids, do: :ok, else: {:error, :candidate_missing}
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
    case Media.get_episode_by_number(item.id, season, episode_number) do
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
      {:ok, media_file} -> {:ok, media_file}
      {:error, changeset} -> {:error, changeset}
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
