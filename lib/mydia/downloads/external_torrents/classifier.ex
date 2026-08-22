defmodule Mydia.Downloads.ExternalTorrents.Classifier do
  @moduledoc """
  Splits foreign client torrents into "Mydia could match this" and "not Mydia's".

  Pure: every input arrives as an argument, so this module never reads a client
  or the library. `Mydia.Downloads.ExternalTorrents` is the I/O shell that
  fetches, subtracts, and feeds it.

  The split is the parsed type and the client's external-torrent policy. A
  `%ParsedFileInfo{type: :movie}` or `:tv_show` from a client Mydia is allowed
  to adopt from lands in `:needs_matching`; `:unknown`, names the release
  validator rejects, and anything from a client the operator told Mydia to
  leave alone land in `:external`. There is no confidence threshold, so a media
  release for a show that is not in the library still lands in
  `:needs_matching` rather than being silently reclassified as junk.
  """

  require Logger

  alias Mydia.Downloads.ExternalPolicy
  alias Mydia.Downloads.ReleaseIntake
  alias Mydia.Downloads.Structs.{CandidatePool, DownloadStatus, ExternalTorrent}
  alias Mydia.Downloads.TorrentMatcher
  alias Mydia.Library.Structs.ParsedFileInfo

  @max_suggestions 3

  @doc """
  Classifies `{client_name, status, decision}` entries into
  `{needs_matching, external}`.

  `decision` comes from `Mydia.Downloads.ExternalPolicy.decide/2`. Only
  `:adopt` entries can reach `:needs_matching`: a torrent Mydia was told not to
  adopt is not a problem to solve, so it renders on the neutral External tab
  rather than under Issues.
  """
  @spec classify(
          [{String.t(), DownloadStatus.t(), ExternalPolicy.decision()}],
          CandidatePool.t()
        ) :: {[ExternalTorrent.t()], [ExternalTorrent.t()]}
  def classify(entries, %CandidatePool{} = pool) do
    entries
    |> Enum.map(fn {client_name, status, decision} ->
      build(client_name, status, decision, pool)
    end)
    |> Enum.split_with(&(&1.kind == :needs_matching))
  end

  defp build(client_name, %DownloadStatus{} = status, decision, pool) do
    base = %ExternalTorrent{
      id: stable_id(client_name, status.id),
      client_name: client_name,
      client_id: status.id,
      title: status.name,
      kind: :external,
      status: status.state,
      progress: status.progress,
      size: status.size,
      download_speed: status.download_speed,
      eta: status.eta,
      ratio: status.ratio,
      save_path: status.save_path,
      parsed: nil,
      suggestions: [],
      excluded_by_policy: decision != :adopt
    }

    case ReleaseIntake.parse_release(status.name) do
      {:ok, %ParsedFileInfo{type: type} = parsed} when type in [:movie, :tv_show] ->
        %{
          base
          | kind: kind_for(decision),
            parsed: parsed,
            suggestions: suggestions_for(decision, parsed, pool)
        }

      {:ok, %ParsedFileInfo{} = parsed} ->
        # :unknown — parsed enough to have a title, not enough to be media.
        %{base | parsed: parsed}

      {:error, _reason} ->
        # Validator rejection or an unparseable name. Surfaced verbatim so the
        # user can still see and match it; no parsed info to show.
        base
    end
  end

  defp kind_for(:adopt), do: :needs_matching
  defp kind_for(_excluded), do: :external

  # A category-scoped exclusion still gets suggestions: the operator plausibly
  # wants a one-off manual pull, and the External tab's match control is right
  # there. An ignored client does not: scoring every foreign torrent on every
  # scan is exactly the work `:ignore` asks Mydia to stop doing.
  defp suggestions_for(:excluded_by_ignore, _parsed, _pool), do: []
  defp suggestions_for(_decision, parsed, pool), do: suggestions(parsed, pool)

  defp suggestions(parsed, pool) do
    TorrentMatcher.find_top_candidates_in(pool, parsed, max_results: @max_suggestions)
  rescue
    e ->
      # Report, do not just log. This rescue silently swallowed the nil-title
      # scoring crash for as long as it has existed: the same defect that
      # aborted DownloadMonitor through the untracked-matching path was
      # invisible here. Degrading to no suggestions is the right behaviour;
      # doing it without a report is not.
      ErrorTracker.report(e, __STACKTRACE__, %{parsed_title: parsed.title})
      Logger.warning("Failed to find match candidates: #{inspect(e)}")
      []
  end

  # Stable across scans so LiveView stream patching updates rows in place
  # instead of tearing them down. The NUL separator keeps {"ab", "c"} and
  # {"a", "bc"} from hashing to the same id.
  defp stable_id(client_name, client_id) do
    :sha256
    |> :crypto.hash("#{client_name}\0#{client_id}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
