defmodule MydiaWeb.MediaLive.Show.CollectionEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Collections

  def toggle_favorite(_params, socket) do
    user = socket.assigns.current_scope.user
    media_item = socket.assigns.media_item

    case Collections.toggle_favorite(user, media_item.id) do
      {:ok, :added} ->
        {:noreply,
         socket
         |> assign(:is_favorite, true)
         |> load_collection_data(media_item)
         |> put_flash(:info, "Added to Favorites")}

      {:ok, :removed} ->
        {:noreply,
         socket
         |> assign(:is_favorite, false)
         |> load_collection_data(media_item)
         |> put_flash(:info, "Removed from Favorites")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to update favorites")}
    end
  end

  def open_add_to_collection_modal(_params, socket) do
    {:noreply, assign(socket, :show_add_to_collection_modal, true)}
  end

  def close_add_to_collection_modal(_params, socket) do
    {:noreply, assign(socket, :show_add_to_collection_modal, false)}
  end

  def add_to_collection(%{"collection-id" => collection_id}, socket) do
    user = socket.assigns.current_scope.user
    media_item = socket.assigns.media_item

    case Collections.get_collection(user, collection_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Collection not found")}

      collection ->
        case Collections.add_item(collection, media_item.id) do
          {:ok, _item} ->
            # Deliberately does not close the modal: a user picking several
            # collections for one item in a single sitting needs the picker
            # to stay open between picks. It closes only from the explicit
            # Close/Cancel/backdrop actions (close_add_to_collection_modal).
            {:noreply,
             socket
             |> load_collection_data(media_item)
             |> put_flash(:info, "Added to #{collection.name}")}

          {:error, :smart_collection} ->
            {:noreply, put_flash(socket, :error, "Cannot add items to smart collections")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to add to collection")}
        end
    end
  end

  def remove_from_collection(%{"collection-id" => collection_id}, socket) do
    user = socket.assigns.current_scope.user
    media_item = socket.assigns.media_item

    case Collections.get_collection(user, collection_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Collection not found")}

      collection ->
        case Collections.remove_item(collection, media_item.id) do
          {:ok, _item} ->
            {:noreply,
             socket
             |> load_collection_data(media_item)
             |> put_flash(:info, "Removed from #{collection.name}")}

          {:error, :smart_collection} ->
            {:noreply, put_flash(socket, :error, "Cannot remove items from smart collections")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Item not in collection")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to remove from collection")}
        end
    end
  end

  @doc """
  Refreshes the favorite/collection read model.

  Called at mount and again after every favorite toggle and collection
  add/remove, so it must never touch `:show_add_to_collection_modal`: doing
  so would force the picker modal closed on its own first successful pick,
  making it impossible to add an item to more than one collection in a
  single sitting. That assign is owned by `open_add_to_collection_modal/2`,
  `close_add_to_collection_modal/2`, and mount's own initial `false`.
  """
  def load_collection_data(socket, media_item) do
    user = socket.assigns.current_scope.user
    is_favorite = Collections.is_favorite?(socket.assigns.current_scope, media_item.id)
    item_collections = Collections.collections_for_item(user, media_item.id)
    user_collections = Collections.list_collections(user, type: "manual", include_shared: false)

    socket
    |> assign(:is_favorite, is_favorite)
    |> assign(:item_collections, item_collections)
    |> assign(:user_collections, user_collections)
  end
end
