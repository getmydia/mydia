defmodule MydiaWeb.Live.ComponentFlash do
  @moduledoc """
  Lets a LiveComponent raise a flash on its parent LiveView.

  A component's `put_flash/3` stays on the component's own socket, and only
  reaches the page through `push_navigate/2` or `push_patch/2`. A component
  that neither navigates nor wants its parent to grow a `handle_info` calls
  `put/2` instead: it messages the LiveView process, and the hook this module
  attaches on mount puts the flash there.
  """

  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3]

  @doc "Shows `message` as a `kind` flash on the LiveView this process runs."
  @spec put(:info | :error, String.t()) :: :ok
  def put(kind, message) when kind in [:info, :error] do
    send(self(), {__MODULE__, kind, message})
    :ok
  end

  def on_mount(:default, _params, _session, socket) do
    {:cont, attach_hook(socket, :component_flash, :handle_info, &handle_info/2)}
  end

  defp handle_info({__MODULE__, kind, message}, socket),
    do: {:halt, put_flash(socket, kind, message)}

  defp handle_info(_message, socket), do: {:cont, socket}
end
