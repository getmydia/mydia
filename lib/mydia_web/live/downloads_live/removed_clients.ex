defmodule MydiaWeb.DownloadsLive.RemovedClients do
  @moduledoc """
  Downloads whose client was removed from the configuration, grouped per
  client for the Downloads page's banners.
  """

  alias Mydia.Downloads
  alias MydiaWeb.DownloadsLive.ListView

  @doc """
  Orphan groups annotated with a DOM-safe slug. Client names come from
  operator-supplied config (env vars), so unlike most other ids on the page
  they aren't guaranteed to already be DOM-id-safe: a name with spaces or
  punctuation would otherwise produce an invalid id/CSS selector. The raw name
  is preserved in `download_client` for display and for the
  `phx-value-client` sent back to `clear_removed_client`.
  """
  @spec groups() :: [map()]
  def groups do
    Downloads.removed_client_groups()
    |> Enum.map_reduce(MapSet.new(), fn group, taken ->
      {slug, taken} = unique_slug(ListView.slugify(group.download_client), taken)
      {Map.put(group, :slug, slug), taken}
    end)
    |> elem(0)
  end

  # Distinct client names can slugify to the same string ("Qbit Old" and
  # "qbit-old"), and anything with no alphanumerics collapses to "client".
  # Duplicate DOM ids are invalid HTML and make LiveView's id-keyed patching
  # apply an update to the wrong banner, so the first claimant keeps the bare
  # slug and later ones get a numeric suffix. `Downloads.removed_client_groups/0`
  # orders by client name, so which one is "first" is stable across renders.
  defp unique_slug(base, taken) do
    if MapSet.member?(taken, base) do
      next_free_slug(base, 2, taken)
    else
      {base, MapSet.put(taken, base)}
    end
  end

  # Skips past a suffix a real client name already claimed, so a group named
  # "qbit-old-2" cannot be stolen from underneath by a disambiguated sibling.
  defp next_free_slug(base, n, taken) do
    candidate = "#{base}-#{n}"

    if MapSet.member?(taken, candidate) do
      next_free_slug(base, n + 1, taken)
    else
      {candidate, MapSet.put(taken, candidate)}
    end
  end
end
