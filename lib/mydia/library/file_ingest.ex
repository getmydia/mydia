defmodule Mydia.Library.FileIngest do
  @moduledoc "Decides whether a durable import candidate stays in review or is promoted."

  alias Mydia.ImportCandidates
  alias Mydia.Library.{CandidatePromotion, ImportCandidate, MediaFile}
  alias Mydia.Repo

  @default_threshold Mydia.ImportGroups.auto_accept_threshold()
  @retry_backoff_seconds [300, 1_800, 7_200, 21_600, 86_400]

  @type policy :: :review | :unattended
  @type result ::
          {:promoted, [MediaFile.t()]}
          | {:candidate, ImportCandidate.t()}
          | {:linked, Mydia.Media.MediaItem.t()}
          | :no_match
          | {:error, term()}

  @spec default_threshold() :: float()
  def default_threshold, do: @default_threshold

  @spec ingest(ImportCandidate.t(), map() | nil, keyword()) :: result()
  @spec ingest(MediaFile.t(), map() | nil, keyword()) :: term()
  def ingest(%ImportCandidate{} = candidate, match, opts) do
    policy = Keyword.fetch!(opts, :policy)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    case decide(match, policy, threshold) do
      :candidate ->
        update_candidate(candidate, match)

      :promote ->
        promotion_opts = Keyword.put(opts, :allow_episode_creation, true)

        case CandidatePromotion.promote_group([candidate], match, promotion_opts) do
          {:ok, media_files} ->
            {:promoted, media_files}

          {:error, reason} ->
            case record_failure(candidate, format_error(reason)) do
              {:ok, _candidate} -> {:error, reason}
              {:error, changeset} -> {:error, {:candidate_write_failed, changeset}}
            end
        end
    end
  end

  # Callers are migrated to durable candidates by the surrounding pipeline
  # tasks. This compatibility clause deliberately cannot create a media file,
  # preserving the no-parentless-file invariant while the call sites move.
  def ingest(%MediaFile{}, _match, _opts), do: {:error, :candidate_required}

  @spec policy_for(Mydia.Settings.LibraryPath.t() | nil, MediaFile.t()) ::
          :local_only | :create_items
  def policy_for(%Mydia.Settings.LibraryPath{auto_import: true}, %MediaFile{extra_kind: nil}),
    do: :create_items

  def policy_for(_library_path, _media_file), do: :local_only

  defp decide(nil, _policy, _threshold), do: :candidate
  defp decide(_match, :review, _threshold), do: :candidate

  defp decide(match, :unattended, threshold) do
    if (Map.get(match, :match_confidence) || 0.0) >= threshold,
      do: :promote,
      else: :candidate
  end

  defp update_candidate(candidate, nil) do
    case record_failure(candidate, "no_match") do
      {:ok, _candidate} -> :no_match
      {:error, changeset} -> {:error, {:candidate_write_failed, changeset}}
    end
  end

  defp update_candidate(candidate, match) do
    case ImportCandidates.upsert(candidate_attrs(candidate, match)) do
      {:ok, updated} -> {:candidate, updated}
      {:error, changeset} -> {:error, {:candidate_write_failed, changeset}}
    end
  end

  defp record_failure(candidate, error) do
    current = Repo.get(ImportCandidate, candidate.id) || candidate
    attempts = current.attempts + 1

    case ImportCandidates.upsert(
           candidate_attrs(current, %{
             attempts: attempts,
             last_error: error,
             next_retry_at: next_retry_at(attempts)
           })
         ) do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp candidate_attrs(candidate, match) do
    parsed = Map.get(match, :parsed_info, candidate.parsed_info || %{})

    %{
      library_path_id: candidate.library_path_id,
      relative_path: candidate.relative_path,
      anchor_key: candidate.anchor_key,
      size: candidate.size,
      mtime: candidate.mtime,
      discovered_at: candidate.discovered_at,
      provider_type: string_or_nil(Map.get(match, :provider_type, candidate.provider_type)),
      provider_id: string_or_nil(Map.get(match, :provider_id, candidate.provider_id)),
      title: Map.get(match, :title, candidate.title),
      year: Map.get(match, :year, candidate.year),
      media_type: string_or_nil(parsed_value(parsed, :type)) || candidate.media_type,
      confidence: Map.get(match, :match_confidence, candidate.confidence),
      parsed_info: storable_parsed_info(parsed),
      attempts: Map.get(match, :attempts, candidate.attempts),
      last_error: Map.get(match, :last_error, nil),
      next_retry_at: Map.get(match, :next_retry_at, nil)
    }
  end

  defp storable_parsed_info(parsed) when is_map(parsed) do
    %{
      "type" => string_or_nil(parsed_value(parsed, :type)),
      "season" => parsed_value(parsed, :season),
      "episodes" => parsed_value(parsed, :episodes) || [],
      "is_sample" => parsed_value(parsed, :is_sample) || false,
      "is_trailer" => parsed_value(parsed, :is_trailer) || false,
      "is_extra" => parsed_value(parsed, :is_extra) || false
    }
  end

  defp storable_parsed_info(_), do: %{}

  defp parsed_value(parsed, key) do
    Map.get(parsed, key) || Map.get(parsed, Atom.to_string(key))
  end

  defp string_or_nil(nil), do: nil
  defp string_or_nil(value), do: to_string(value)

  defp next_retry_at(attempts) do
    seconds = Enum.at(@retry_backoff_seconds, attempts - 1, List.last(@retry_backoff_seconds))
    DateTime.utc_now() |> DateTime.add(seconds, :second) |> DateTime.truncate(:second)
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
