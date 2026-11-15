defmodule MydiaWeb.DownloadsLive.BuiltInDisk do
  @moduledoc """
  Keeps the downloads page's `:built_in_disk` assign in step with the built-in
  torrent client's disk state, for the low-disk banner.

  `mount/1` reads the state once and attaches a `handle_info` hook for the
  status broadcasts, so the LiveView itself needs no clause for them. When the
  client is off the assign stays `:ok` and no banner shows.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.Status

  @doc "Assigns `:built_in_disk`, subscribes when connected, and hooks the broadcasts."
  def mount(socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Mydia.PubSub, Status.topic())

    socket
    |> assign(:built_in_disk, read_disk())
    |> attach_hook(:built_in_disk, :handle_info, &handle_info/2)
  end

  defp handle_info({:built_in_status, %Status{disk: disk}}, socket),
    do: {:halt, assign(socket, :built_in_disk, disk)}

  defp handle_info(_msg, socket), do: {:cont, socket}

  # The Status process is an Agent, so a call exits when it is absent.
  defp read_disk do
    if BuiltIn.runtime(), do: Status.get().disk, else: :ok
  catch
    :exit, _ -> :ok
  end
end
