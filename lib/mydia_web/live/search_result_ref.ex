defmodule MydiaWeb.Live.SearchResultRef do
  @moduledoc """
  An opaque reference to a search result, for `phx-value-*` attributes.

  A release's `download_url` can carry the searching account's tracker
  passkey, so it never goes into the page: a row sends this reference and the
  LiveView looks the result up among the results it already holds. The
  reference is a truncated SHA-256 of the URL and the tracker, so it reveals
  neither, and is stable for the same release across re-renders.
  """

  @doc "The reference for a result (anything with `:download_url` and `:indexer`)."
  # The title keeps two linkless results from one tracker apart.
  @spec ref(map()) :: String.t()
  def ref(%{download_url: url, indexer: indexer} = result) do
    :sha256
    |> :crypto.hash([url || "", 0, indexer || "", 0, Map.get(result, :title) || ""])
    |> binary_part(0, 12)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  The result in `results` (a list, or a map whose values are results) whose
  reference is `ref`, or nil.
  """
  @spec find(map() | [map()], String.t() | nil) :: map() | nil
  def find(_results, ref) when not is_binary(ref), do: nil
  def find(results, ref) when is_map(results), do: find(Map.values(results), ref)
  def find(results, ref) when is_list(results), do: Enum.find(results, &(ref(&1) == ref))
end
