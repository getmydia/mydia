defmodule MydiaWeb.MediaLive.Index.AlphaJump do
  @moduledoc """
  The server side of the library listing's letter jump: the phone picker's
  `jump_letter` event, the version that rebuilds its select, and the scroll
  push shared with the strip's patch links.
  """
  import Phoenix.Component, only: [update: 3]
  import Phoenix.LiveView, only: [push_event: 3, push_patch: 2]

  # The same patch the strip's links make, looked up in the server's own paths
  # so the client cannot choose the destination.
  def jump_letter(socket, letter) do
    case socket.assigns.letter_paths do
      %{^letter => path} ->
        # Rebuilding the select puts the placeholder back, so choosing the
        # same letter again is a change and jumps again.
        socket = update(socket, :alpha_picker_version, &(&1 + 1))

        # A patch to the letter already in the URL changes nothing, so scroll
        # back to it directly, as the strip's hook does.
        if socket.assigns.letter == letter do
          {:noreply, maybe_scroll_to_letter(socket, letter)}
        else
          {:noreply, push_patch(socket, to: path, replace: true)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def maybe_scroll_to_letter(socket, nil_or_false) when nil_or_false in [nil, false], do: socket

  # The letter lets the client land on that letter's first card: after
  # load_previous prepended earlier rows, the top of the list is no longer it.
  def maybe_scroll_to_letter(socket, letter),
    do: push_event(socket, "alpha_jump:scroll_top", %{letter: letter})
end
