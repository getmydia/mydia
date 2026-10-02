defmodule MydiaWeb.DashboardLive.ShelfRail do
  @moduledoc """
  A plugin shelf as the dashboard renders it: a heading and cards.

  Cards are `Mydia.Metadata.Structs.SearchResult`s, the shape every other rail
  on the page uses, so they work with `trending_card/1`, the detail modal and
  the add and request flows unchanged. Each also carries `:reason` and
  `:shelf_item_id`.
  """

  alias Mydia.Metadata.Structs.SearchResult
  alias Mydia.Plugins.ShelfItem
  alias Mydia.Plugins.Shelves.View
  alias MydiaWeb.Live.Helpers.MediaAddHelpers
  alias MydiaWeb.Live.Helpers.MediaRequestHelpers

  @enforce_keys [:id, :title, :items]
  defstruct [:id, :title, :items]

  @type t :: %__MODULE__{id: String.t(), title: String.t(), items: [map()]}

  @doc "Builds one rail per shelf that has items. A shelf with none yields no rail."
  @spec build([View.t()], map(), map()) :: [t()]
  def build(views, library_status_map, request_status_map) do
    for %View{declared: declared, items: [_ | _] = items} <- views do
      %__MODULE__{
        id: "shelf-#{declared.slug}-#{declared.key}",
        title: declared.title,
        items: items |> Enum.map(&card/1) |> enrich(library_status_map, request_status_map)
      }
    end
  end

  @doc "Re-applies library and request status after either map changed."
  @spec reenrich([t()], map(), map()) :: [t()]
  def reenrich(rails, library_status_map, request_status_map) do
    Enum.map(rails, fn %__MODULE__{} = rail ->
      %{rail | items: enrich(rail.items, library_status_map, request_status_map)}
    end)
  end

  @doc "Every card on every rail, for lookups that span rails."
  @spec items([t()]) :: [map()]
  def items(rails), do: Enum.flat_map(rails, & &1.items)

  defp card(%ShelfItem{} = item) do
    Map.merge(
      %SearchResult{
        provider_id: to_string(item.provider_id),
        provider: item.provider,
        media_type: item.media_type,
        title: item.title,
        year: item.year,
        poster_path: item.poster_path
      },
      %{reason: item.reason, shelf_item_id: item.id}
    )
  end

  defp enrich(cards, library_status_map, request_status_map) do
    cards
    |> MediaAddHelpers.enrich_with_library_status(library_status_map)
    |> MediaRequestHelpers.enrich_with_request_status(request_status_map)
  end
end
