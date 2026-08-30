defmodule Mydia.Library.ScriptedMatcher do
  @moduledoc """
  A matcher whose verdict is read out of the path itself, for tests that need
  several distinct, deterministic outcomes (confident, ambiguous, no match)
  in the same scan without cross-process state.

  Deliberately stateless like `Mydia.Library.EchoMatcher`: `BatchMatcher` fans
  its work out under `Mydia.TaskSupervisor`, where a process dictionary or a
  named Agent would not reach every worker or would collide across async
  tests.

  A path containing `"NOMATCH"` (case-sensitive, checked against the full
  path so it can live in a directory or file name) returns `{:error,
  :no_match}`. A path containing `"AMBIGUOUS"` returns a real match pinned at
  `match_confidence: 0.5`, below every sane auto-accept threshold. Every
  other path returns a confident match (`match_confidence: 0.95`) against
  `provider_id/0` -- a caller that wants that match to promote all the way
  through `Mydia.Library.CandidatePromotion` with no relay call anywhere in
  the chain should create a local `media_item_fixture(tmdb_id: provider_id(),
  ...)` first: `MetadataEnricher` links to an existing local item by provider
  id before it ever considers a fetch, and a just-created item is inside its
  "recently enriched" window, so no re-fetch is attempted either.

  `parsed_info` is always the real `Mydia.Library.ReleaseParser.parse_with_path/1`
  result for the path given, so season/episode/extra classification is
  accurate regardless of which branch above produced the rest of the match.
  """

  @behaviour Mydia.Library.Matcher

  alias Mydia.Library.ReleaseParser

  @provider_id "748219"
  @title "Scripted Movie"
  @year 1999

  @doc "The tmdb id every confident/ambiguous verdict below carries."
  def provider_id, do: @provider_id

  @doc "The title every confident/ambiguous verdict below carries."
  def title, do: @title

  @doc "The year every confident/ambiguous verdict below carries."
  def year, do: @year

  @impl true
  def match_file(path, _opts) do
    cond do
      String.contains?(path, "NOMATCH") -> {:error, :no_match}
      String.contains?(path, "AMBIGUOUS") -> {:ok, confident(path, 0.5)}
      true -> {:ok, confident(path, 0.95)}
    end
  end

  defp confident(path, match_confidence) do
    %{
      provider_id: @provider_id,
      provider_type: :tmdb,
      title: @title,
      year: @year,
      match_confidence: match_confidence,
      metadata: %{},
      from_local_db: false,
      parsed_info: ReleaseParser.parse_with_path(path)
    }
  end
end
