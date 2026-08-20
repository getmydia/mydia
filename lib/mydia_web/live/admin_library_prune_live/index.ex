defmodule MydiaWeb.AdminLibraryPruneLive.Index do
  @moduledoc """
  Reviews and confirms pruning of redundant duplicate files.

  The plan is computed on every render rather than cached. It is a couple of
  queries over a few hundred groups, and a stale plan is a correctness problem
  rather than a performance one.
  """

  use MydiaWeb, :live_view

  import MydiaWeb.AdminLibraryPruneLive.Components

  alias Mydia.Library.Prune

  # Mirrors Mydia.Jobs.TrashCleanup's default, so this page never quotes a
  # retention period that disagrees with what actually purges trashed files.
  @default_retention_days 30

  @impl true
  def mount(_params, _session, socket) do
    retention_days = Application.get_env(:mydia, :trash_retention_days, @default_retention_days)

    {:ok,
     socket
     |> assign(:page_title, "Prune duplicate files")
     |> assign(:selected, MapSet.new())
     |> assign(:keepers, %{})
     |> assign(:retention_days, retention_days)
     |> load_plan()}
  end

  @impl true
  def handle_event("choose_keeper", %{"subject" => subject_id, "file" => file_id}, socket) do
    keepers = Map.put(socket.assigns.keepers, subject_id, file_id)

    # The chosen keeper can no longer be a selected loser.
    selected = MapSet.delete(socket.assigns.selected, file_id)

    {:noreply,
     socket
     |> assign(:keepers, keepers)
     |> assign(:selected, selected)
     |> load_plan()}
  end

  def handle_event("toggle_loser", %{"file" => file_id}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected, file_id) do
        MapSet.delete(socket.assigns.selected, file_id)
      else
        MapSet.put(socket.assigns.selected, file_id)
      end

    {:noreply, socket |> assign(:selected, selected) |> assign_reclaimable()}
  end

  def handle_event("confirm", _params, socket) do
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
     |> assign(:selected, MapSet.new())
     |> load_plan()}
  end

  defp load_plan(socket) do
    plan = Prune.plan(socket.assigns.keepers)

    socket
    |> assign(decisions: plan.decisions, refusals: plan.refusals)
    |> assign_reclaimable()
  end

  # Recomputed wherever `:selected` or `:decisions` changes, so the byte count
  # on the confirm button can never disagree with the checkboxes above it.
  defp assign_reclaimable(socket) do
    selected = socket.assigns.selected

    bytes =
      for decision <- socket.assigns.decisions,
          file <- decision.losers,
          MapSet.member?(selected, file.id),
          reduce: 0 do
        total -> total + (file.size || 0)
      end

    assign(socket, :reclaimable, bytes)
  end

  defp flash_for(%{trashed: trashed, failed: failed, aborted: aborted}) do
    base = "Trashed #{length(trashed)} file(s)."
    base = if failed == [], do: base, else: base <> " #{length(failed)} could not be moved."

    if aborted == [],
      do: base,
      else: base <> " #{length(aborted)} were skipped by re-verification."
  end
end
