defmodule Mydia.Library.FailingMatcher do
  @moduledoc "A matcher that never resolves anything, for the failure path."

  @behaviour Mydia.Library.Matcher

  @impl true
  def match_file(_path, _opts), do: {:error, :no_match}
end
