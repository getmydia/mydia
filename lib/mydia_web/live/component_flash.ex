defmodule MydiaWeb.Live.ComponentFlash do
  @moduledoc """
  Lets a LiveComponent raise a flash on its parent LiveView, or reload it.

  A component's `put_flash/3` stays on the component's own socket, and only
  reaches the page through `push_navigate/2` or `push_patch/2`. A component
  that neither navigates nor wants its parent to grow a `handle_info` calls
  `put/2` instead: it messages the LiveView process, and the hook this module
  attaches on mount puts the flash there.

  `reload/0` is the same for a component whose action changed what its
  parent shows: the parent navigates to its own URL and mounts afresh,
  keeping the flashes put before it.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3, push_navigate: 2]
  import Phoenix.Component, only: [assign: 3]

  @doc "Shows `message` as a `kind` flash on the LiveView this process runs."
  @spec put(:info | :error, String.t()) :: :ok
  def put(kind, message) when kind in [:info, :error] do
    send(self(), {__MODULE__, kind, message})
    :ok
  end

  @doc "Reloads the LiveView this process runs at its current URL."
  @spec reload() :: :ok
  def reload do
    send(self(), {__MODULE__, :reload})
    :ok
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> attach_hook(:component_flash, :handle_info, &handle_info/2)
     |> attach_hook(:component_flash_uri, :handle_params, &remember_uri/3)}
  end

  defp remember_uri(_params, uri, socket),
    do: {:cont, assign(socket, :component_flash_uri, URI.parse(uri))}

  # A navigation carries only the flashes put in the same callback, so the
  # ones already showing are put again.
  defp handle_info({__MODULE__, :reload}, socket) do
    case socket.assigns[:component_flash_uri] do
      %URI{path: path, query: query} ->
        socket = Enum.reduce(socket.assigns.flash, socket, fn {k, v}, s -> put_flash(s, k, v) end)
        {:halt, push_navigate(socket, to: if(query, do: "#{path}?#{query}", else: path))}

      nil ->
        {:halt, socket}
    end
  end

  defp handle_info({__MODULE__, kind, message}, socket),
    do: {:halt, put_flash(socket, kind, message)}

  defp handle_info(_message, socket), do: {:cont, socket}
end
