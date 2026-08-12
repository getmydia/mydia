defmodule Mydia.Indexers.Cardigann.Links do
  @moduledoc """
  Builds the ordered list of base URL candidates for a Cardigann definition.

  Candidates are the definition's `links` in order, followed by its
  `legacylinks`. Upstream Jackett and Prowlarr use `legacylinks` only to migrate
  a stored site URL to the current one, never as alternates to try. Mydia
  deliberately appends them: public trackers rotate through those domains, and
  41 of the 80 public v11 definitions ship them, so a dead-domain recovery path
  is worth more than strict parity. Legacy candidates are always last, so a live
  primary is never displaced by a stale domain.
  """

  alias Mydia.Indexers.CardigannDefinition.Parsed

  @doc """
  Returns the ordered, de-duplicated candidate base URLs for a definition.
  """
  @spec candidates(Parsed.t()) :: [String.t()]
  def candidates(%Parsed{} = parsed) do
    (normalize_list(parsed.links) ++ normalize_list(parsed.legacylinks))
    |> Enum.uniq()
  end

  defp normalize_list(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.trim_trailing("/")))
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list(_), do: []
end
