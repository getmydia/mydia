defmodule Mydia.Downloads.ExternalTorrents.Classifier do
  @moduledoc """
  Splits foreign client torrents into "Mydia could match this" and "not Mydia's".

  Pure: every input arrives as an argument, so this module never reads a client
  or the library. `Mydia.Downloads.ExternalTorrents` is the I/O shell that
  fetches, subtracts, and feeds it.

  The split is the parsed type and nothing else. `%ParsedFileInfo{type: :movie}`
  and `:tv_show` are things Mydia can plausibly own; `:unknown` and names the
  release validator rejects are not. There is no confidence threshold, so a
  media release for a show that is not in the library still lands in
  `:needs_matching` rather than being silently reclassified as junk.
  """

  require Logger

  alias Mydia.Downloads.ReleaseIntake
  alias Mydia.Downloads.Structs.{CandidatePool, DownloadStatus, ExternalTorrent}
  alias Mydia.Downloads.TorrentMatcher
  alias Mydia.Library.Structs.ParsedFileInfo

  @max_suggestions 3

  @doc """
  Classifies `{client_name, status}` entries into `{needs_matching, external}`.
  """
  @spec classify([{String.t(), DownloadStatus.t()}], CandidatePool.t()) ::
          {[ExternalTorrent.t()], [ExternalTorrent.t()]}
  def classify(entries, %CandidatePool{} = pool) do
    entries
    |> Enum.map(fn {client_name, status} -> build(client_name, status, pool) end)
    |> Enum.split_with(&(&1.kind == :needs_matching))
  end

  defp build(client_name, %DownloadStatus{} = status, pool) do
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
      suggestions: []
    }

    case ReleaseIntake.parse_release(status.name) do
      {:ok, %ParsedFileInfo{type: type} = parsed} when type in [:movie, :tv_show] ->
        %{
          base
          | kind: :needs_matching,
            parsed: parsed,
            suggestions: suggestions(parsed, pool)
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

  defp suggestions(parsed, pool) do
    TorrentMatcher.find_top_candidates_in(pool, parsed, max_results: @max_suggestions)
  rescue
    e ->
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
