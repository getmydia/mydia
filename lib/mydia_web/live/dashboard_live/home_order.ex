defmodule MydiaWeb.DashboardLive.HomeOrder do
  @moduledoc """
  Reordering the visible Home widgets from the Customize Home modal: moving
  one widget up or down, and applying a full order from a drag.

  Every function takes the LiveView socket and returns a
  `{:reply, %{keys: [...]}, socket}` carrying the saved order, so the client
  hook can resync rows it moved itself. `MydiaWeb.DashboardLive.Index` keeps
  one-line event clauses.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Accounts
  alias Mydia.Accounts.HomeLayout

  @doc "Moves one widget up or down. An unknown key replies with the current order."
  def move(socket, %{"key" => raw_key, "direction" => dir_str}) do
    direction = if dir_str == "up", do: :up, else: :down

    case HomeLayout.to_key(raw_key) do
      nil ->
        reply_home_order(socket)

      key ->
        socket
        |> save_home_order(HomeLayout.move(socket.assigns.home_widgets, key, direction))
        |> reply_home_order()
    end
  end

  def move(socket, _params), do: reply_home_order(socket)

  @doc "Applies a full widget order in one event. Bad params reply with the current order."
  def reorder(socket, %{"keys" => keys}) when is_list(keys) do
    socket
    |> save_home_order(HomeLayout.reorder(socket.assigns.home_widgets, keys))
    |> reply_home_order()
  end

  def reorder(socket, _params), do: reply_home_order(socket)

  # Persists a new widget order. An unchanged order skips the write; a failed
  # save keeps the old assigns and flashes.
  defp save_home_order(socket, new_widgets) do
    if new_widgets == socket.assigns.home_widgets do
      socket
    else
      case Accounts.put_home_widgets(socket.assigns.current_user, new_widgets) do
        {:ok, _pref} -> assign(socket, :home_widgets, new_widgets)
        {:error, _} -> put_flash(socket, :error, "Could not save your Home layout.")
      end
    end
  end

  # The reply carries the authoritative saved order so the client can resync
  # rows it moved itself (LiveView sends no diff when assigns did not change).
  defp reply_home_order(socket) do
    {:reply, %{keys: Enum.map(socket.assigns.home_widgets, &Atom.to_string/1)}, socket}
  end
end
