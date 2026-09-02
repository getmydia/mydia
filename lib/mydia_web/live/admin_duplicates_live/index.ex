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

  ## Two scopes, two confirmations

  A group can be trashed on its own, and the whole library can be trashed at
  once. Only the second gets a confirmation modal: two files in one item and
  forty-seven across twenty-three are different blast radii, and the modal is
  worth its click only for the second.

  What the group run gets instead is `:last_run` and the undo toast. It holds
  the ids the run trashed until another run replaces it, the operator dismisses
  it, or they leave the page. `Mydia.Library.Prune.undo/2` puts those files
  back, and the restored ids join `:kept` on the way through for the same
  reason `:kept` survives a run at all: they are losers of an eligible group
  again, and a loser defaults to Trash, so without that the page would offer to
  trash the copies just rescued.

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
  alias MydiaWeb.AdminDuplicatesLive.Components

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
     |> assign(:last_run, nil)
     |> assign(:retention_days, retention_days)
     |> load_plan()}
  end

  @impl true
  def handle_event("keep_file", %{"subject" => subject_id, "file" => file_id}, socket) do
    {:noreply, update_kept(socket, subject_id, file_id, &MapSet.put/2)}
  end

  def handle_event("trash_file", %{"subject" => subject_id, "file" => file_id}, socket) do
    case find_decision(socket, subject_id) do
      nil ->
        {:noreply, socket}

      decision when decision.keeper.id == file_id ->
        {:noreply, promote_successor(socket, decision, file_id)}

      _decision ->
        {:noreply, update_kept(socket, subject_id, file_id, &MapSet.delete/2)}
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

  # Runs the trash for one group instead of the whole library. The ids are
  # narrowed to that group's marked losers, and `keepers` still goes through:
  # `execute/3` rebuilds the plan, and without the overrides it would re-rank
  # the group with the default keeper and discard whatever the operator's Keep
  # and Trash choices implied.
  def handle_event("trash_group_now", %{"subject" => subject_id}, socket) do
    with decision when not is_nil(decision) <- find_decision(socket, subject_id),
         ids = group_selection(socket, decision),
         false <- ids == [] do
      actor_id = to_string(socket.assigns.current_scope.user.id)
      result = Prune.execute(ids, actor_id, socket.assigns.keepers)
      label = "from #{Components.subject_label(decision.group)}"

      {:noreply,
       socket
       |> report_run(result, label)
       |> load_plan()}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("undo_trash", _params, %{assigns: %{last_run: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("undo_trash", _params, socket) do
    actor_id = to_string(socket.assigns.current_scope.user.id)
    result = Prune.undo(socket.assigns.last_run.file_ids, actor_id)

    # A restored file is a loser of an eligible group again, and every loser of
    # an eligible group defaults to Trash. Without this the page would put the
    # rescued copies straight back on Trash and offer to trash them again,
    # which reads as the page ignoring the operator.
    kept =
      Enum.reduce(result.restored, socket.assigns.kept, &MapSet.put(&2, &1.id))

    socket =
      if result.failed == [] do
        socket
      else
        put_flash(socket, :error, "#{length(result.failed)} file(s) could not be restored.")
      end

    # The toast clears either way. The run is over, and a second Undo on the
    # same ids would find them untrashed and do nothing.
    {:noreply,
     socket
     |> assign(:kept, kept)
     |> assign(:last_run, nil)
     |> load_plan()}
  end

  def handle_event("dismiss_undo", _params, socket) do
    {:noreply, assign(socket, :last_run, nil)}
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

    # `label` is computed before `load_plan/1` runs, because `load_plan/1`
    # recomputes `:affected_items` against the post-run plan.
    label = "across #{Components.item_count(socket.assigns.affected_items)}"

    # `:kept` survives the run. A group can still hold two files afterwards (a
    # keeper plus a copy the operator set to Keep), and it stays eligible, so
    # clearing the set would list that survivor as a loser and put it straight
    # back on Trash, offering to trash the very file the operator just spared.
    # Nothing needs pruning out of the set either: `:selected` is built from
    # the losers *not* in `:kept`, so the ids just trashed were never in it.
    {:noreply,
     socket
     |> report_run(result, label)
     |> assign(:show_trash_modal, false)
     |> load_plan()}
  end

  # Trashing the keeper hands the group to another copy rather than emptying
  # it. Preference order: the best-ranked loser the operator has already set
  # to Keep, then the best-ranked loser overall. `losers` arrives in rank
  # order from `Mydia.Library.Prune.Ranker`, so `Enum.find/2` walks it
  # best-first.
  #
  # Both the promoted file and the demoted keeper leave `:kept`. The successor
  # must, since it stops being a loser and would otherwise sit in the set as a
  # keeper. The demoted keeper is belt and braces: `keep_file` only admits
  # losers, so a current keeper cannot be in the set, and dropping it here
  # keeps that true no matter which handler grows the set later. Were it left
  # behind it would return as a kept loser and silently swallow the click that
  # demoted it.
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

  # Both row controls move one loser in or out of `:kept`, and both take the
  # subject and the file from the event. The set only moves when the decision
  # named by the event actually holds that file.
  #
  # The keeper is excluded on purpose: it is already kept, so `keep_file` on it
  # is a no-op, and `trash_file` on it is a promotion handled before this is
  # reached. Admitting it would leave the current keeper's id sitting in the
  # set, outliving the group it came from.
  #
  # Pairing one group's subject with another group's file is not something the
  # page can produce. It must not move the set either: on a page that trashes
  # files, that is the difference between a spared copy staying spared and
  # quietly going back on Trash under a group the operator was not looking at.
  defp update_kept(socket, subject_id, file_id, fun) do
    decision = find_decision(socket, subject_id)

    if decision && Enum.any?(decision.losers, &(&1.id == file_id)) do
      socket
      |> assign(:kept, fun.(socket.assigns.kept, file_id))
      |> assign_selection()
    else
      socket
    end
  end

  defp find_decision(socket, subject_id),
    do: Enum.find(socket.assigns.decisions, &(&1.group.subject_id == subject_id))

  defp group_selection(socket, decision) do
    for file <- decision.losers,
        MapSet.member?(socket.assigns.selected, file.id),
        do: file.id
  end

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

  # A clean run says everything it needs to in the undo toast, so no info flash
  # is raised: two success messages saying the same thing is noise. Failures
  # and aborts still go through the flash, so a partial run shows the error at
  # the top and the undo at the bottom, which is the truth: some files moved
  # and can be put back, and some did not.
  defp report_run(socket, result, scope_label) do
    socket
    |> maybe_flash_problems(result)
    |> maybe_set_last_run(result, scope_label)
  end

  defp maybe_flash_problems(socket, %{failed: [], aborted: []}), do: socket

  defp maybe_flash_problems(socket, %{failed: failed, aborted: aborted}) do
    parts =
      [
        failed != [] && "#{length(failed)} could not be moved",
        aborted != [] && "#{length(aborted)} were skipped by re-verification"
      ]
      |> Enum.filter(& &1)

    put_flash(socket, :error, Enum.join(parts, ". ") <> ".")
  end

  defp maybe_set_last_run(socket, %{trashed: []}, _scope_label), do: socket

  defp maybe_set_last_run(socket, %{trashed: trashed}, scope_label) do
    bytes = trashed |> Enum.map(&(&1.size || 0)) |> Enum.sum()

    assign(socket, :last_run, %{
      file_ids: Enum.map(trashed, & &1.id),
      label:
        "Trashed #{Components.file_count(length(trashed))} #{scope_label} " <>
          "(#{Components.humanize_bytes(bytes)})"
    })
  end
end
