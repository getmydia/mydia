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

  @doc """
  The definition's own `links` in order, without the `legacylinks` that
  `candidates/1` appends. Prowlarr's engine rewrites a legacy link to the first
  link, so a legacy candidate is no alternative to it.
  """
  @spec current(Parsed.t()) :: [String.t()]
  def current(%Parsed{} = parsed), do: parsed.links |> normalize_list() |> Enum.uniq()

  # Rendered keywords are already percent-encoded; static text in a path template
  # is not. Encode only what a request target cannot carry (space, controls,
  # non-ASCII bytes, and characters like '"', '<', '>', '{', '}', '|', '\\', '^'
  # and the backtick, which Mint's request target validation rejects). Reserved
  # and unreserved characters and '%' are left alone so existing escapes and
  # query strings survive.
  @doc false
  @spec encode_path_text(String.t()) :: String.t()
  def encode_path_text(path), do: URI.encode(path, &(URI.char_unescaped?(&1) or &1 == ?%))

  defp normalize_list(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(&1 |> String.trim() |> String.trim_trailing("/")))
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_list(_), do: []
end
