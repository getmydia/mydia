defmodule MydiaWeb.ImportMediaLive.Expansion do
  @moduledoc """
  Which group rows `MydiaWeb.ImportMediaLive.Index` shows open when it loads a
  page of groups.

  `@expanded_ids` holds every open row (the chevron); `@expanded_group_id` is
  the one row whose members are loaded into `@streams.members`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream: 4]

  alias Mydia.ImportCandidates

  @doc """
  Sets `@expanded_ids` for `groups`, the page about to replace the one in
  `@page_group_ids`, then reconciles `@expanded_group_id` with it.

  With `preserve?` false (paging, band, search, library switch) every group
  gets the on-load rule. With `preserve?` true (the PubSub refresh, which
  reloads the same page under the user's hands, their own episode edits
  included) a group already on the page keeps the state the user left it in,
  and only a group new to the page gets the on-load rule.
  """
  def apply_page(socket, groups, preserve?) do
    previous_ids = if preserve?, do: MapSet.new(socket.assigns.page_group_ids), else: MapSet.new()
    expanded_ids = socket.assigns.expanded_ids

    expanded =
      groups
      |> Enum.filter(&open?(&1, previous_ids, expanded_ids))
      |> MapSet.new(& &1.id)

    socket
    |> assign(:expanded_ids, expanded)
    |> reconcile_loaded_group()
  end

  defp open?(group, previous_ids, expanded_ids) do
    if MapSet.member?(previous_ids, group.id),
      do: MapSet.member?(expanded_ids, group.id),
      else: open_on_load?(group)
  end

  # A settled group starts closed, an unsettled one starts open -- same
  # rule the wizard this page replaced applied per season.
  defp open_on_load?(group), do: ImportCandidates.band(group) != :ready

  # The group whose members are loaded must still be on the page and open,
  # or its member list goes: accepted or dismissed elsewhere, paged past, or
  # closed by the on-load rule. One that survives gets its members re-read,
  # since the caller's `stream(:groups, ..., reset: true)` re-renders every
  # row and the `:members` stream would otherwise have nothing to send that
  # row.
  defp reconcile_loaded_group(%{assigns: %{expanded_group_id: nil}} = socket), do: socket

  defp reconcile_loaded_group(%{assigns: %{expanded_group_id: anchor_key}} = socket) do
    if MapSet.member?(socket.assigns.expanded_ids, anchor_key) do
      library_path_id = socket.assigns.selected_library_path_id
      stream(socket, :members, ImportCandidates.members(library_path_id, anchor_key), reset: true)
    else
      socket
      |> assign(:expanded_group_id, nil)
      |> stream(:members, [], reset: true)
    end
  end
end
