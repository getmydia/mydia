defmodule Mydia.Library.CrashingMatcher do
  @moduledoc """
  A matcher that always reports a hard failure (not a "no match" verdict).

  Distinct from `Mydia.Library.FailingMatcher`, whose `{:error, :no_match}`
  is a legitimate, recordable outcome. This is for exercising the genuine
  failure path -- e.g. `Mydia.ImportCandidates.rematch/2`'s `:failures`
  counter -- where the matcher itself could not produce any verdict at all.
  """

  @behaviour Mydia.Library.Matcher

  @impl true
  def match_file(_path, _opts), do: {:error, :boom}
end
