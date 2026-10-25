defmodule MydiaWeb.DashboardLive.ShelfFeedback do
  @moduledoc """
  Thumbs feedback on the home dashboard's plugin shelves: rating a card,
  undoing a rating, and recording that a shelf title was added.

  Every function takes the LiveView socket and returns it, so
  `MydiaWeb.DashboardLive.Index` keeps one-line event clauses.
  """

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Mydia.Metadata.Ref
  alias Mydia.Plugins.Shelves
  alias MydiaWeb.DashboardLive.ShelfRail
  alias MydiaWeb.Live.Helpers.DetailModal

  @doc "Mount state: no shelves loaded yet and no rating to undo."
  def init(socket) do
    socket
    |> assign(:shelves, [])
    |> assign(:undo_shelf_item, nil)
    |> assign(:undo_shelf_message, nil)
  end

  @doc "Rates a shelf card up or down and offers an undo. Bad params are ignored."
  def rate(socket, %{"id" => item_id, "rating" => rating})
      when is_binary(item_id) and rating in ["up", "down"] do
    rating_atom = if rating == "up", do: :up, else: :down

    # An unknown or foreign id is ignored: the reload is the answer either way.
    case Shelves.rate_item(socket.assigns.current_user, item_id, rating_atom) do
      {:ok, item} ->
        socket
        |> assign(:undo_shelf_item, item)
        |> assign(:undo_shelf_message, rated_message(rating, item.title))
        |> close_details_for_shelf_item(item_id)
        |> reload_shelves()

      {:error, :not_found} ->
        reload_shelves(socket)
    end
  end

  def rate(socket, _params), do: socket

  @doc "Takes back the last rating, if one is pending."
  def undo(socket) do
    case socket.assigns.undo_shelf_item do
      nil ->
        socket

      item ->
        Shelves.undo_rating(socket.assigns.current_user, item)

        socket
        |> assign(:undo_shelf_item, nil)
        |> assign(:undo_shelf_message, nil)
        |> reload_shelves()
    end
  end

  @doc """
  A successful add or request of a title that sits on a shelf is a good pick.
  Reloads so the card swaps its thumbs for the "Good pick, noted" line.
  """
  def record_add(socket, ref, media_type) do
    provider = Ref.provider(ref)
    id = to_string(Ref.id(ref))

    card =
      Enum.find(ShelfRail.items(socket.assigns.shelves), fn card ->
        card.provider == provider and card.provider_id == id and card.media_type == media_type
      end)

    case card && Shelves.record_added(socket.assigns.current_user, card.shelf_item_id) do
      :ok -> reload_shelves(socket)
      _ -> socket
    end
  end

  defp reload_shelves(socket) do
    views = Shelves.list_for(socket.assigns.current_user, :home)

    assign(
      socket,
      :shelves,
      ShelfRail.build(views, socket.assigns.library_status_map, socket.assigns.request_status_map)
    )
  end

  defp rated_message("up", title),
    do: gettext("Noted. %{title} won't be suggested again.", title: title)

  defp rated_message("down", title),
    do: gettext("%{title} won't be suggested again.", title: title)

  # Rating from the details dialog removes the card the dialog was opened from.
  defp close_details_for_shelf_item(socket, item_id) do
    case socket.assigns.selected_item do
      %{shelf_item_id: ^item_id} -> DetailModal.close(socket)
      _ -> socket
    end
  end
end
