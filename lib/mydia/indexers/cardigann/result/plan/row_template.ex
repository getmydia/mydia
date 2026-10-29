defmodule Mydia.Indexers.Cardigann.Result.Plan.RowTemplate do
  @moduledoc false
  # A filter argument the plan could not render because it reads a row's
  # `.Result`. Every other argument leaves the plan as its final string, so the
  # per-row code renders exactly these and nothing else. Telling the two apart
  # by looking for `.Result` in the string would also re-render a plan output
  # whose keyword or setting happened to contain that text; Prowlarr renders
  # each argument once (`CardigannBase.ApplyFilters`), substituting variables
  # as literal text.

  @type t :: %__MODULE__{template: String.t()}

  @enforce_keys [:template]
  defstruct [:template]
end
