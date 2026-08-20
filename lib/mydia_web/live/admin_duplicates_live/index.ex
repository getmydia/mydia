defmodule MydiaWeb.AdminDuplicatesLive.Index do
  @moduledoc """
  Reviews duplicate files and confirms trashing the redundant copies.

  The plan is computed on every render rather than cached. It is a couple of
  queries over a few hundred groups, and a stale plan is a correctness problem
  rather than a performance one.

  ## One control per file

  Every file row carries a single Keep/Trash choice. There is no separate
  "which one is the keeper" control: the keeper is simply the best-ranked copy
  that is still set to Keep, so the operator never has to reconcile two
  widgets that mean overlapping things.

  Trashing the current keeper is therefore a promotion, not an error. The
  best-ranked copy the operator has already set to Keep takes over, and only
  if there is none does the next-ranked copy get promoted (and un-trashed) to
  stand in its place. That keeps the invariant every group needs: at least one
  file always survives, so the Trash button can never empty an item.

  ## Why the selection is stored as an exclusion set

  Every loser of every eligible group starts on Trash, so the ordinary path
  through this page is one click on the Trash button. Holding the operator's
  *Keep* choices rather than their Trash choices is what keeps that true
  across a re-plan: when the keeper changes, the file that stopped being the
  keeper becomes a loser and goes to Trash without the operator hunting for
  it, while everything they explicitly set to Keep stays on Keep.

  Defaulting to Trash is only defensible because `Mydia.Library.Prune.Eligibility`
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
     |> assign(:page_title, "Configuration - Duplicates")
     |> assign(:active_tab, :duplicates)
     |> assign(:kept, MapSet.new())
     |> assign(:keepers, %{})
     |> assign(:show_trash_modal, false)
     |> assign(:retention_days, retention_days)
     |> load_plan()}
  end

  @impl true
  def handle_event("keep_file", %{"file" => file_id}, socket) do
    # Only losers can move: the keeper is already kept, and marking it again
    # would be a no-op that still costs a re-plan.
    {:noreply,
     socket
     |> assign(:kept, MapSet.put(socket.assigns.kept, file_id))
     |> assign_selection()}
  end

  def handle_event("trash_file", %{"subject" => subject_id, "file" => file_id}, socket) do
    case find_decision(socket, subject_id) do
      nil ->
        {:noreply, socket}

      decision when decision.keeper.id == file_id ->
        {:noreply, promote_successor(socket, decision, file_id)}

      _decision ->
        {:noreply,
         socket
         |> assign(:kept, MapSet.delete(socket.assigns.kept, file_id))
         |> assign_selection()}
    end
  end

  def handle_event("keep_group", %{"subject" => subject_id}, socket) do
    case find_decision(socket, subject_id) do
      nil ->
        {:noreply, socket}

      decision ->
        kept =
          Enum.reduce(decision.losers, socket.assigns.kept, &MapSet.put(&2, &1.id))

        {:noreply, socket |> assign(:kept, kept) |> assign_selection()}
    end
  end

  def handle_event("trash_group", %{"subject" => subject_id}, socket) do
    case find_decision(socket, subject_id) do
      nil ->
        {:noreply, socket}

      decision ->
        kept =
          Enum.reduce(decision.losers, socket.assigns.kept, &MapSet.delete(&2, &1.id))

        {:noreply, socket |> assign(:kept, kept) |> assign_selection()}
    end
  end

  def handle_event("trash_all_duplicates", _params, socket) do
    {:noreply, socket |> assign(:kept, MapSet.new()) |> assign_selection()}
  end

  def handle_event("open_trash_modal", _params, socket) do
    {:noreply, assign(socket, :show_trash_modal, MapSet.size(socket.assigns.selected) > 0)}
  end

  def handle_event("close_trash_modal", _params, socket) do
    {:noreply, assign(socket, :show_trash_modal, false)}
  end

  def handle_event("confirm_trash", _params, socket) do
    actor_id = to_string(socket.assigns.current_scope.user.id)

    # execute/3 must be given the same keeper overrides the plan on screen was
    # built from. Without them, execute/3 silently re-ranks every group with
    # the default keeper, discarding whatever override the operator's Keep and
    # Trash choices implied before they confirmed.
    result =
      Prune.execute(MapSet.to_list(socket.assigns.selected), actor_id, socket.assigns.keepers)

    # `:kept` survives the run. A group can still hold two files afterwards (a
    # keeper plus a copy the operator set to Keep), and it stays eligible, so
    # clearing the set would list that survivor as a loser and put it straight
    # back on Trash — offering to trash the very file the operator just spared.
    # Nothing needs pruning out of the set either: `:selected` is built from
    # the losers *not* in `:kept`, so the ids just trashed were never in it.
    {:noreply,
     socket
     |> put_flash(:info, flash_for(result))
     |> assign(:show_trash_modal, false)
     |> load_plan()}
  end

  # Trashing the keeper hands the group to another copy rather than emptying
  # it. Preference order: the best-ranked loser the operator has already set
  # to Keep, then the best-ranked loser overall. `losers` arrives in rank
  # order from `Mydia.Library.Prune.Ranker`, so `Enum.find/2` walks it
  # best-first. Both the promoted file and the demoted keeper leave `:kept`:
  # the successor stops being a loser at all, and the demoted keeper has to be
  # clear of the Keep set or it would come back as a kept loser and quietly
  # ignore the click that demoted it.
  defp promote_successor(socket, decision, keeper_id) do
    kept = socket.assigns.kept

    successor =
      Enum.find(decision.losers, &MapSet.member?(kept, &1.id)) || List.first(decision.losers)

    case successor do
      nil ->
        socket

      file ->
        socket
        |> assign(:keepers, Map.put(socket.assigns.keepers, decision.group.subject_id, file.id))
        |> assign(:kept, kept |> MapSet.delete(file.id) |> MapSet.delete(keeper_id))
        |> load_plan()
    end
  end

  defp find_decision(socket, subject_id),
    do: Enum.find(socket.assigns.decisions, &(&1.group.subject_id == subject_id))

  defp load_plan(socket) do
    plan = Prune.plan(socket.assigns.keepers)

    socket
    |> assign(decisions: plan.decisions, refusals: plan.refusals)
    |> assign_selection()
  end

  # `:selected` is derived, never stored: every loser of an eligible group is
  # bound for the trash unless the operator set it to Keep. Recomputed
  # wherever `:kept` or `:decisions` changes, so the counts on the Trash
  # button can never disagree with the rows above it.
  defp assign_selection(socket) do
    kept = socket.assigns.kept

    selected =
      for decision <- socket.assigns.decisions,
          file <- decision.losers,
          not MapSet.member?(kept, file.id),
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
