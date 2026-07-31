defmodule MydiaWeb.MediaLive.Show.CategoryEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Media
  alias MydiaWeb.Live.Authorization

  import MydiaWeb.MediaLive.Show.Loaders, only: [load_media_item: 1]

  def show_category_modal(_params, socket) do
    media_item = socket.assigns.media_item

    changeset =
      Media.change_media_item_category(media_item, %{
        category: media_item.category,
        category_override: media_item.category_override
      })

    {:noreply,
     socket
     |> assign(:show_category_modal, true)
     |> assign(:category_form, Phoenix.Component.to_form(changeset))}
  end

  def hide_category_modal(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_category_modal, false)
     |> assign(:category_form, nil)}
  end

  def show_trailer_modal(_params, socket) do
    {:noreply, assign(socket, :show_trailer_modal, true)}
  end

  def hide_trailer_modal(_params, socket) do
    {:noreply, assign(socket, :show_trailer_modal, false)}
  end

  def validate_category(%{"media_item" => params}, socket) do
    changeset =
      socket.assigns.media_item
      |> Media.change_media_item_category(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :category_form, Phoenix.Component.to_form(changeset))}
  end

  def save_category(%{"media_item" => params}, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      media_item = socket.assigns.media_item
      params = Map.put(params, "category_override", params["override"] == "true")

      case Media.update_media_item(media_item, params, reason: "Category updated") do
        {:ok, updated_item} ->
          {:noreply,
           socket
           |> assign(:media_item, updated_item)
           |> assign(:show_category_modal, false)
           |> assign(:category_form, nil)
           |> put_flash(:info, "Category updated successfully")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :category_form, Phoenix.Component.to_form(changeset))}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def reset_category_to_auto(_params, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      media_item = socket.assigns.media_item
      new_category = Mydia.Media.CategoryClassifier.classify(media_item)

      case Media.update_media_item(
             media_item,
             %{category: new_category, category_override: false},
             reason: "Category reset to auto-detected"
           ) do
        {:ok, updated_item} ->
          {:noreply,
           socket
           |> assign(:media_item, updated_item)
           |> assign(:show_category_modal, false)
           |> assign(:category_form, nil)
           |> put_flash(
             :info,
             "Category reset to auto-detected: #{category_display_name(new_category)}"
           )}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           socket
           |> assign(:category_form, Phoenix.Component.to_form(changeset))
           |> put_flash(:error, "Failed to reset category")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  def update_quality_profile(%{"profile-id" => profile_id}, socket) do
    with :ok <- Authorization.authorize_update_media(socket) do
      media_item = socket.assigns.media_item
      quality_profile_id = if profile_id == "", do: nil, else: profile_id

      case Media.update_media_item(
             media_item,
             %{quality_profile_id: quality_profile_id},
             reason: "Quality profile updated"
           ) do
        {:ok, _updated_item} ->
          reloaded_item = load_media_item(media_item.id)

          {:noreply,
           socket
           |> assign(:media_item, reloaded_item)
           |> put_flash(:info, "Quality profile updated")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to update quality profile")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  # Category helper functions

  defp category_display_name(:movie), do: "Movie"
  defp category_display_name(:anime_movie), do: "Anime Movie"
  defp category_display_name(:cartoon_movie), do: "Cartoon Movie"
  defp category_display_name(:tv_show), do: "TV Show"
  defp category_display_name(:anime_series), do: "Anime Series"
  defp category_display_name(:cartoon_series), do: "Cartoon Series"
  defp category_display_name(cat), do: to_string(cat)
end
