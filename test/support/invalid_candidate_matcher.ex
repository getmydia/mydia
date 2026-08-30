defmodule Mydia.Library.InvalidCandidateMatcher do
  @moduledoc """
  A matcher whose result `FileIngest` can neither link nor write as a
  candidate -- the exact progress-contract violation
  `Jobs.ImportRun.verify_match_phase_complete/2` exists to catch after the
  keyset match loop reports the phase "done".

  `match_confidence: 2.0` is outside `ImportCandidate.changeset/2`'s
  `validate_number(:confidence, greater_than_or_equal_to: 0.0,
  less_than_or_equal_to: 1.0)`, so `Mydia.ImportCandidates.upsert/1` returns a
  real `{:error, changeset}` -- this is not a match `FileIngest` chooses to
  reject, it is one it genuinely fails to record. Under the `:review` policy
  this write failure surfaces as `FileIngest.ingest/3` returning
  `{:error, {:candidate_write_failed, _}}` for the candidate, leaving it with
  no match, no retry timestamp, and no dismissal.
  """

  @behaviour Mydia.Library.Matcher

  @impl true
  def match_file(_path, _opts) do
    {:ok,
     %{
       provider_id: "invalid",
       provider_type: :tvdb,
       title: "Invalid Candidate",
       year: nil,
       match_confidence: 2.0
     }}
  end
end
