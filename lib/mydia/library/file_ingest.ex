defmodule Mydia.Library.FileIngest do
  @moduledoc """
  The per-file "match, decide, commit" step, shared by the scheduled library
  scan and the user-started import coordinator.

  Both callers do the same three things with a matched file. They differ only
  in when they are willing to create a new `MediaItem`, which is expressed here
  as a policy rather than as a flag threaded through either caller:

    * `:local_only` links only a match that came from the local database. An
      external provider match is cached as a candidate and the file stays
      orphaned. This is what `Jobs.LibraryScanner` has always done and must
      keep doing, so the scheduled scan never invents items behind the user.

    * `:create_items` links any match at or above the confidence threshold,
      creating the `MediaItem` if it does not exist. This is what a user-started
      import run does in unattended mode.

  Anything not linked is written as a `MatchCandidate`, which is what lets the
  review inbox render without touching the relay and what lets a resumed run
  skip files a previous run already matched.
  """

  require Logger

  alias Mydia.Library
  alias Mydia.Library.{MediaFile, MetadataEnricher}
  alias Mydia.Metadata

  @default_threshold 0.8

  @type policy :: :local_only | :create_items
  @type result ::
          {:linked, Mydia.Media.MediaItem.t()}
          | {:candidate, Library.MatchCandidate.t()}
          | :no_match
          | {:error, term()}

  @doc """
  The confidence at or above which `:create_items` links automatically.

  0.8 deliberately matches the threshold the old import wizard used to
  pre-tick matches at, so users see the same matches accepted automatically
  that they were already accepting by hand.
  """
  @spec default_threshold() :: float()
  def default_threshold, do: @default_threshold

  @doc """
  Decides what to do with a matched file and commits that decision.

  See the module doc for the policies. Returns `:no_match` when the matcher
  found nothing, in which case the attempt is still recorded so the inbox can
  show that the file was tried.
  """
  @spec ingest(MediaFile.t(), map() | nil, keyword()) :: result()
  def ingest(%MediaFile{} = media_file, match_result, opts) do
    policy = Keyword.fetch!(opts, :policy)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    case decide(match_result, policy, threshold) do
      :no_match ->
        record_failure(media_file, "no_match")
        :no_match

      :candidate ->
        {:ok, candidate} = write_candidate(media_file, match_result)
        {:candidate, candidate}

      :link ->
        link(media_file, match_result, opts)
    end
  end

  ## Decision

  defp decide(nil, _policy, _threshold), do: :no_match

  defp decide(match, :local_only, _threshold) do
    if Map.get(match, :from_local_db, false), do: :link, else: :candidate
  end

  defp decide(match, :create_items, threshold) do
    if (Map.get(match, :match_confidence) || 0.0) >= threshold, do: :link, else: :candidate
  end

  ## Commit

  defp link(media_file, match_result, opts) do
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()

    case MetadataEnricher.enrich(match_result, config: config, media_file_id: media_file.id) do
      {:ok, media_item} ->
        # The file now has a parent, so it is no longer inbox work.
        Library.delete_match_candidates(media_file.id)
        {:linked, media_item}

      {:error, reason} ->
        Logger.warning("Failed to link media file",
          media_file_id: media_file.id,
          title: Map.get(match_result, :title),
          reason: inspect(reason)
        )

        record_failure(media_file, format_error(reason))
        {:error, reason}
    end
  end

  defp write_candidate(media_file, match) do
    parsed = Map.get(match, :parsed_info) || %{}

    Library.upsert_match_candidate(%{
      media_file_id: media_file.id,
      rank: 0,
      provider_type: to_string_or_nil(Map.get(match, :provider_type)),
      provider_id: to_string_or_nil(Map.get(match, :provider_id)),
      title: Map.get(match, :title),
      year: Map.get(match, :year),
      media_type: to_string_or_nil(Map.get(parsed, :type)),
      confidence: Map.get(match, :match_confidence),
      parsed_info: storable_parsed_info(parsed),
      attempts: 0,
      last_error: nil
    })
  end

  defp record_failure(media_file, error) do
    previous =
      case Library.list_match_candidates(media_file.id) do
        [%{rank: 0} = existing | _] -> existing.attempts
        _ -> 0
      end

    Library.upsert_match_candidate(%{
      media_file_id: media_file.id,
      rank: 0,
      attempts: previous + 1,
      last_error: error
    })
  end

  ## Helpers

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  # parsed_info arrives with atom keys and atom values from ReleaseParser.
  # JsonMapType round-trips through JSON, so atoms must be stringified on the
  # way in or they come back as strings and silently fail later comparisons.
  defp storable_parsed_info(parsed) when is_map(parsed) do
    Map.new(parsed, fn
      {k, v} when is_atom(v) and not is_boolean(v) and not is_nil(v) ->
        {to_string(k), to_string(v)}

      {k, v} ->
        {to_string(k), v}
    end)
  end

  defp storable_parsed_info(_), do: %{}

  defp format_error({:invalid_match_result, message}), do: message
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
