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

  ## The progress contract

  Every call to `ingest/3` must leave the file either with a parent
  (`media_item_id` or `episode_id`) or with a rank-0 `MatchCandidate`. Those
  two sets are exactly what `Library.list_unmatched_media_file_paths/2`
  excludes, so a file that ends up in neither is outstanding work forever:
  `Jobs.ImportRun`'s match loop reselects it on every pass and never
  terminates.

  This is why `{:linked, item}` is only returned once the file has been
  re-read and confirmed to have a parent. `MetadataEnricher.enrich/2` returns
  `{:ok, media_item}` in several cases where it associated nothing at all (a
  TV episode row that does not exist for the parsed season/episode, parsed
  info with no episode numbers, a movie association whose update failed), so
  its `:ok` is a statement about the item, not about the file. Making the
  check local to this module is what keeps loop termination a property
  something owns, rather than one that emerges from three modules agreeing.
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

  `{:linked, item}` means the file provably has a `media_item_id` or an
  `episode_id` after this call, verified by re-reading the row. A match that
  enriched an item but associated nothing comes back as
  `{:error, {:not_associated, message}}` with the candidate left in place, so
  the file stays visible in the inbox with a reason instead of vanishing from
  both the inbox and the unmatched set. See the module doc's progress
  contract, which the import coordinator's loop termination depends on.
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
        confirm_association(media_file, media_item, match_result)

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

  # `enrich/2` returning {:ok, item} says the item exists, not that this file
  # was attached to it. Re-read the row and check, because that is the whole
  # progress contract (see the moduledoc): a file with neither a parent nor a
  # candidate is invisible in the inbox, invisible to the health check's
  # orphan count, and still selected by every subsequent match chunk.
  defp confirm_association(media_file, media_item, match_result) do
    reloaded = Library.get_media_file!(media_file.id)

    if is_nil(reloaded.media_item_id) and is_nil(reloaded.episode_id) do
      message = not_associated_message(match_result)

      Logger.warning("Enrichment succeeded but the media file was never associated",
        media_file_id: media_file.id,
        media_item_id: media_item.id,
        title: Map.get(match_result, :title)
      )

      # Deliberately NOT delete_match_candidates/1: the candidate is the only
      # thing keeping this file reachable. Write the full match first so the
      # inbox can show what was found, then stamp the reason onto the same
      # rank-0 row.
      write_candidate(media_file, match_result)
      record_failure(media_file, message)

      {:error, {:not_associated, message}}
    else
      # The file now has a parent, so it is no longer inbox work.
      Library.delete_match_candidates(media_file.id)
      {:linked, media_item}
    end
  end

  # Written for a self-hosted operator reading the inbox, not for a log
  # grepper: this string is rendered verbatim by
  # `MydiaWeb.ImportMediaLive.Inbox.format_last_error/1`.
  defp not_associated_message(match_result) do
    title = Map.get(match_result, :title) || "that title"
    parsed = Map.get(match_result, :parsed_info) || %{}
    season = get_parsed(parsed, :season)
    episodes = get_parsed(parsed, :episodes) || []

    if get_parsed(parsed, :type) == :tv_show and not is_nil(season) and episodes != [] do
      "Matched #{title} but season #{season} episode #{Enum.join(episodes, ", ")} does not exist on it, so nothing was added."
    else
      "Matched #{title} but this file could not be attached to it, so nothing was added."
    end
  end

  # Logs rather than discarding, for the same reason `record_failure/2` does.
  # This row is the one the inbox renders (title, provider, confidence), so a
  # silent failure here leaves a file listed with none of what was found about
  # it. `ingest/3`'s `:candidate` branch still hard-matches the `{:ok, _}`,
  # which is deliberate: that path has no fallback write behind it.
  defp write_candidate(media_file, match) do
    case do_write_candidate(media_file, match) do
      {:ok, candidate} ->
        {:ok, candidate}

      {:error, changeset} ->
        Logger.error("Could not cache a match candidate for a media file",
          media_file_id: media_file.id,
          title: Map.get(match, :title),
          errors: inspect(changeset.errors)
        )

        {:error, changeset}
    end
  end

  defp do_write_candidate(media_file, match) do
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

  # The write result is matched rather than discarded. A dropped candidate is
  # the one input that breaks the moduledoc's progress contract from the
  # inside: the file ends up with no parent and no candidate, which is what
  # `Jobs.ImportRun`'s match loop treats as "still to do" forever. There is
  # nothing useful to do about it here beyond refusing to be quiet, so it logs
  # at :error and hands the changeset back.
  defp record_failure(media_file, error) do
    previous =
      case Library.list_match_candidates(media_file.id) do
        [%{rank: 0} = existing | _] -> existing.attempts
        _ -> 0
      end

    case Library.upsert_match_candidate(%{
           media_file_id: media_file.id,
           rank: 0,
           attempts: previous + 1,
           last_error: error
         }) do
      {:ok, candidate} ->
        {:ok, candidate}

      {:error, changeset} ->
        Logger.error("Could not record a match failure, the file will be retried indefinitely",
          media_file_id: media_file.id,
          attempted_error: error,
          errors: inspect(changeset.errors)
        )

        {:error, changeset}
    end
  end

  ## Helpers

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value), do: to_string(value)

  # In production `parsed` is a %ParsedFileInfo{} (set by MetadataMatcher from
  # ReleaseParser.parse_with_path/2), not a plain map, so this cannot walk the
  # struct generically: it carries a nested %Quality{} struct (no
  # Jason.Encoder) and a dozen parser internals that have no business in this
  # column, and dumping the whole thing would fail to encode. Store an
  # explicit projection of only the fields the inbox and Tasks 10/13 read
  # back. Every value below is already JSON-native (integers, booleans, a
  # list of integers) except :type, which is stringified explicitly here to
  # document the on-disk contract even though Jason would stringify a bare
  # atom on its own.
  defp storable_parsed_info(nil), do: %{}

  defp storable_parsed_info(parsed) when is_map(parsed) do
    %{
      "type" => to_string_or_nil(get_parsed(parsed, :type)),
      "season" => get_parsed(parsed, :season),
      "episodes" => get_parsed(parsed, :episodes) || [],
      "is_sample" => get_parsed(parsed, :is_sample) || false,
      "is_trailer" => get_parsed(parsed, :is_trailer) || false,
      "is_extra" => get_parsed(parsed, :is_extra) || false
    }
  end

  defp storable_parsed_info(_), do: %{}

  # Accepts both a %ParsedFileInfo{} and a plain map: tests build the latter,
  # production always hands ingest/3 the former. Map.get/2 works on both
  # without requiring the Enumerable protocol a bare struct doesn't implement.
  defp get_parsed(parsed, key) when is_map(parsed), do: Map.get(parsed, key)

  # TRAP: do not add a clause for `:library_type_mismatch` here.
  #
  # `{:library_type_mismatch, message}` deliberately falls through to the
  # `inspect/1` catch-all below, and the inbox's "Wrong library" badge keys on
  # exactly that: `MydiaWeb.ImportMediaLive.Inbox.library_type_mismatch?/1`
  # tests `String.starts_with?(last_error, "{:library_type_mismatch,")`.
  # Unwrapping the tuple here would store the bare message, the badge would
  # stop rendering, and nothing would fail: the sentence still displays, so
  # the loss is silent and only visible by eye. `Jobs.LibraryScanner`'s
  # `scan_result_from_ingest/1` pattern-matches the same tagged tuple.
  # If this ever needs to change, change the badge predicate in the same
  # commit.
  defp format_error({:invalid_match_result, message}), do: message
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
