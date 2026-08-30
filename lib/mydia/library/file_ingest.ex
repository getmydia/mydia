defmodule Mydia.Library.FileIngest do
  @moduledoc "Decides whether a durable import candidate stays in review or is promoted."

  import Ecto.Query, only: [where: 3]

  alias Mydia.ImportCandidates
  alias Mydia.Library.{CandidatePromotion, ImportCandidate, MediaFile}
  alias Mydia.Repo

  @default_threshold Mydia.ImportGroups.auto_accept_threshold()
  @retry_backoff_seconds [300, 1_800, 7_200, 21_600, 86_400]

  @type policy :: :review | :unattended
  @type result ::
          {:promoted, [MediaFile.t()]}
          | {:candidate, ImportCandidate.t()}
          | :no_match
          | {:error, term()}

  @spec default_threshold() :: float()
  def default_threshold, do: @default_threshold

  @spec ingest(ImportCandidate.t(), map() | nil, keyword()) :: result()
  @spec ingest(MediaFile.t(), map() | nil, keyword()) :: term()
  def ingest(%ImportCandidate{} = candidate, match, opts) do
    policy = Keyword.fetch!(opts, :policy)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    case decide(candidate, match, policy, threshold) do
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
              {:error, :candidate_missing} -> {:error, reason}
              {:error, changeset} -> {:error, {:candidate_write_failed, changeset}}
            end
        end
    end
  end

  # Callers are migrated to durable candidates by the surrounding pipeline
  # tasks. This compatibility clause deliberately cannot create a media file,
  # preserving the no-parentless-file invariant while the call sites move.
  def ingest(%MediaFile{}, _match, _opts), do: {:error, :candidate_required}

  defp decide(_candidate, nil, _policy, _threshold), do: :candidate
  defp decide(_candidate, _match, :review, _threshold), do: :candidate

  defp decide(candidate, match, :unattended, threshold) do
    cond do
      extra?(candidate, match) -> :candidate
      (Map.get(match, :match_confidence) || 0.0) >= threshold -> :promote
      true -> :candidate
    end
  end

  # Extras stay in review even under the unattended scanner policy: a
  # sample/trailer/bonus file has no business becoming an owned movie or
  # episode file just because the anchor folder it sits in matched
  # confidently (`Mydia.Library.BatchMatcher` reuses one anchor's match
  # across every file beneath it, extras included). `match.parsed_info` is
  # preferred because it reflects the match just made; a matcher that omits
  # it falls back to the candidate's own stored `parsed_info`, captured at
  # discovery time.
  defp extra?(candidate, match) do
    parsed = match_parsed_info(candidate, match)

    parsed_value(parsed, :is_sample) == true or
      parsed_value(parsed, :is_trailer) == true or
      parsed_value(parsed, :is_extra) == true
  end

  defp match_parsed_info(candidate, match) do
    case match && Map.get(match, :parsed_info) do
      nil -> candidate.parsed_info || %{}
      parsed -> parsed
    end
  end

  defp update_candidate(candidate, nil) do
    case record_failure(candidate, "no_match") do
      {:ok, _candidate} -> :no_match
      {:error, :candidate_missing} -> :no_match
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
    {updated, _} =
      ImportCandidate
      |> where([stored], stored.id == ^candidate.id)
      |> Repo.update_all(
        inc: [attempts: 1],
        set: [
          last_error: error,
          next_retry_at: next_retry_at(candidate.attempts + 1)
        ]
      )

    if updated == 1 do
      {:ok, :updated}
    else
      {:error, :candidate_missing}
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
