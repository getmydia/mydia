defmodule MydiaWeb.MediaLive.Show.AvailabilityEvents do
  @moduledoc false

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Media
  alias MydiaWeb.Live.Authorization

  def handle_event("availability:show", _params, socket),
    do: {:noreply, assign(socket, :show_availability_modal, true)}

  def handle_event("availability:hide", _params, socket),
    do: {:noreply, assign(socket, :show_availability_modal, false)}

  def handle_event("availability:set", params, socket),
    do: set_minimum_availability(params, socket)

  # The Server default row sends "default" rather than an empty value, so the
  # reset never depends on an empty phx-value surviving the round trip. It is
  # stored as NULL.
  defp set_minimum_availability(%{"level" => "default"}, socket) do
    persist(socket, nil, gettext("Search start now follows the server default"))
  end

  defp set_minimum_availability(%{"level" => level}, socket) when is_binary(level) do
    persist(socket, level, gettext("Search start updated"))
  end

  # A malformed event is not a request to reset the choice.
  defp set_minimum_availability(_params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Could not save when search starts"))}
  end

  defp persist(socket, level, message) do
    with :ok <- Authorization.authorize_update_media(socket) do
      media_item = socket.assigns.media_item

      case Media.update_media_item(
             socket.assigns.current_scope,
             media_item,
             %{minimum_availability: level},
             reason: "Minimum availability updated"
           ) do
        {:ok, updated} ->
          {:noreply,
           socket
           |> assign(:media_item, %{
             media_item
             | minimum_availability: updated.minimum_availability
           })
           |> assign(:show_availability_modal, false)
           |> put_flash(:info, message)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, gettext("Could not save when search starts"))}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end
end
