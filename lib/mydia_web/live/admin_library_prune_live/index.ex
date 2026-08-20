defmodule MydiaWeb.AdminLibraryPruneLive.Index do
  @moduledoc """
  Reviews and confirms pruning of redundant duplicate files.

  The plan is computed on every render rather than cached. It is a couple of
  queries over a few hundred groups, and a stale plan is a correctness problem
  rather than a performance one.

  ## Why the selection is stored as an exclusion set

  Every loser of every eligible group starts selected, so the ordinary path
  through this page is one click on Trash. Holding the operator's
  *deselections* rather than their selections is what keeps that true across a
  re-plan: when the keeper changes, the file that stopped being the keeper
  becomes a loser and is selected without the operator hunting for it, while
  everything they explicitly unchecked stays unchecked.

  Selecting by default is only defensible because `Mydia.Library.Prune.Eligibility`
  has already refused every group that is not proven to be the same content.
  A group that reaches `:decisions` holds redundant copies of one file; the
  refused ones are listed separately and have nothing selectable on them.
  """

  use MydiaWeb, :live_view

  alias Mydia.Library.Prune

  # Mirrors Mydia.Jobs.TrashCleanup's default, so this page never quotes a
  # retention period that disagrees with what actually purges trashed files.
  @default_retention_days 30

  @impl true
  def mount(_params, _session, socket) do
    retention_days = Application.get_env(:mydia, :trash_retention_days, @default_retention_days)

    {:ok,
     socket
     |> assign(:page_title, "Configuration - Prune Duplicates")
     |> assign(:active_tab, :prune)
     |> assign(:deselected, MapSet.new())
     |> assign(:keepers, %{})
     |> assign(:show_prune_modal, false)
     |> assign(:retention_days, retention_days)
     |> load_plan()}
  end

  @impl true
  def handle_event("choose_prune_keeper", %{"subject" => subject_id, "file" => file_id}, socket) do
    keepers = Map.put(socket.assigns.keepers, subject_id, file_id)

    # The new keeper drops out of `:losers` on the next plan, so it stops being
    # selected without touching `:deselected`. The old keeper becomes a loser
    # and, never having been unchecked, is selected.
    {:noreply, socket |> assign(:keepers, keepers) |> load_plan()}
  end

  def handle_event("toggle_prune_file", %{"file" => file_id}, socket) do
    deselected =
      if MapSet.member?(socket.assigns.deselected, file_id) do
        MapSet.delete(socket.assigns.deselected, file_id)
      else
        MapSet.put(socket.assigns.deselected, file_id)
      end

    {:noreply, socket |> assign(:deselected, deselected) |> assign_selection()}
  end

  def handle_event("toggle_prune_group", %{"subject" => subject_id}, socket) do
    case Enum.find(socket.assigns.decisions, &(&1.group.subject_id == subject_id)) do
      nil ->
        {:noreply, socket}

      decision ->
        loser_ids = Enum.map(decision.losers, & &1.id)
        selected = socket.assigns.selected

        deselected =
          if Enum.any?(loser_ids, &MapSet.member?(selected, &1)) do
            Enum.reduce(loser_ids, socket.assigns.deselected, &MapSet.put(&2, &1))
          else
            Enum.reduce(loser_ids, socket.assigns.deselected, &MapSet.delete(&2, &1))
          end

        {:noreply, socket |> assign(:deselected, deselected) |> assign_selection()}
    end
  end

  def handle_event("select_all_prune_files", _params, socket) do
    {:noreply, socket |> assign(:deselected, MapSet.new()) |> assign_selection()}
  end

  def handle_event("open_prune_modal", _params, socket) do
    {:noreply, assign(socket, :show_prune_modal, MapSet.size(socket.assigns.selected) > 0)}
  end

  def handle_event("close_prune_modal", _params, socket) do
    {:noreply, assign(socket, :show_prune_modal, false)}
  end

  def handle_event("confirm_prune", _params, socket) do
    actor_id = to_string(socket.assigns.current_scope.user.id)

    # execute/3 must be given the same keeper overrides the plan on screen was
    # built from. Without them, execute/3 silently re-ranks every group with
    # the default keeper, discarding whatever override the operator chose
    # before confirming.
    result =
      Prune.execute(MapSet.to_list(socket.assigns.selected), actor_id, socket.assigns.keepers)

    {:noreply,
     socket
     |> put_flash(:info, flash_for(result))
     |> assign(:show_prune_modal, false)
     |> assign(:deselected, MapSet.new())
     |> load_plan()}
  end

  defp load_plan(socket) do
    plan = Prune.plan(socket.assigns.keepers)

    socket
    |> assign(decisions: plan.decisions, refusals: plan.refusals)
    |> assign_selection()
  end

  # `:selected` is derived, never stored: every loser of an eligible group is
  # selected unless the operator unchecked it. Recomputed wherever
  # `:deselected` or `:decisions` changes, so the counts on the confirm button
  # can never disagree with the checkboxes above it.
  defp assign_selection(socket) do
    deselected = socket.assigns.deselected

    selected =
      for decision <- socket.assigns.decisions,
          file <- decision.losers,
          not MapSet.member?(deselected, file.id),
          into: MapSet.new(),
          do: file.id

    bytes =
      for decision <- socket.assigns.decisions,
          file <- decision.losers,
          MapSet.member?(selected, file.id),
          reduce: 0 do
        total -> total + (file.size || 0)
      end

    affected =
      Enum.count(socket.assigns.decisions, fn decision ->
        Enum.any?(decision.losers, &MapSet.member?(selected, &1.id))
      end)

    socket
    |> assign(:selected, selected)
    |> assign(:reclaimable, bytes)
    |> assign(:affected_items, affected)
  end

  defp flash_for(%{trashed: trashed, failed: failed, aborted: aborted}) do
    base = "Trashed #{length(trashed)} file(s)."
    base = if failed == [], do: base, else: base <> " #{length(failed)} could not be moved."

    if aborted == [],
      do: base,
      else: base <> " #{length(aborted)} were skipped by re-verification."
  end
end
