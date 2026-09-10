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

  @impl true
  def mount(_params, _session, socket) do
    retention_days = Mydia.Config.get().media.trash_retention_days

    {:ok,
     socket
     |> assign(:page_title, "Configuration - Duplicates")
     |> assign(:active_tab, :duplicates)
     |> assign(:kept, MapSet.new())
     |> assign(:keepers, %{})
     |> assign(:review_overrides, %{})
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

  def handle_event("leave_file", %{"subject" => subject_id, "file" => file_id}, socket) do
    {:noreply, put_review_override(socket, subject_id, file_id, :leave)}
  end

  def handle_event("review_file", %{"subject" => subject_id, "file" => file_id}, socket) do
    {:noreply, put_review_override(socket, subject_id, file_id, :review)}
  end

  # Sends one refused group's marked files at once, with no modal, for the same
  # reason trash_group_now has none: one item's files are a small, visible
  # blast radius. Nothing is destroyed either; /review can reattach them.
  def handle_event("send_group_to_review", %{"subject" => subject_id}, socket) do
    with group when not is_nil(group) <- find_refused_group(socket, subject_id),
         ids =
           for(
             file <- group.files,
             MapSet.member?(socket.assigns.returning, file.id),
             do: file.id
           ),
         false <- ids == [] do
      {:noreply, run_send(socket, ids, "from #{Components.subject_label(group)}")}
    else
      _ -> {:noreply, socket}
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

  # A send to Review has nothing to undo here; its toast links to /review
  # instead, so only a forged event arrives with this shape.
  def handle_event("undo_trash", _params, %{assigns: %{last_run: %{kind: :review}}} = socket) do
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
    |> assign(decisions: plan.decisions, refusals: plan.refusals, suspects: plan.suspects)
    |> assign_selection()
    |> prune_review_overrides()
    |> assign_review_selection()
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

  # `:returning` is derived, never stored, the same way `:selected` is for the
  # trash. A file follows the operator's override if there is one. Otherwise it
  # goes to Review only when it is a suspect in a group that also holds a real
  # version that is not: a group whose only other files are extras, or that has
  # none, is left alone, because nothing in it says which file is right.
  defp assign_review_selection(socket) do
    %{refusals: refusals, suspects: suspects, review_overrides: overrides} = socket.assigns

    per_group =
      for {group, reason, _detail} <- refusals, reason != :duplicate_registration do
        group_suspects = Map.get(suspects, group.subject_id, MapSet.new())

        anchored? =
          Enum.any?(
            group.files,
            &(is_nil(&1.extra_kind) and not MapSet.member?(group_suspects, &1.id))
          )

        Enum.filter(group.files, &review?(&1, group_suspects, anchored?, overrides))
      end

    socket
    |> assign(:returning, per_group |> List.flatten() |> MapSet.new(& &1.id))
    |> assign(:returning_items, Enum.count(per_group, &(&1 != [])))
  end

  defp review?(file, group_suspects, anchored?, overrides) do
    case Map.fetch(overrides, file.id) do
      {:ok, disposition} -> disposition == :review
      :error -> anchored? and MapSet.member?(group_suspects, file.id)
    end
  end

  # A Leave/Review click moves one file's override, but only for a file of the
  # refused group the event names, and never onto Review for that group's last
  # file still on Leave: an item always keeps a file. That radio is disabled,
  # so reaching the refusal here means a forged event.
  defp put_review_override(socket, subject_id, file_id, disposition) do
    group = find_refused_group(socket, subject_id)

    cond do
      is_nil(group) ->
        socket

      not Enum.any?(group.files, &(&1.id == file_id)) ->
        socket

      disposition == :review and last_left?(socket, group, file_id) ->
        socket

      true ->
        socket
        |> assign(
          :review_overrides,
          Map.put(socket.assigns.review_overrides, file_id, disposition)
        )
        |> assign_review_selection()
    end
  end

  defp last_left?(socket, group, file_id) do
    case Enum.reject(group.files, &MapSet.member?(socket.assigns.returning, &1.id)) do
      [%{id: ^file_id}] -> true
      _ -> false
    end
  end

  defp find_refused_group(socket, subject_id) do
    Enum.find_value(socket.assigns.refusals, fn {group, reason, _detail} ->
      if reason != :duplicate_registration and group.subject_id == subject_id, do: group
    end)
  end

  # An override lives only as long as its file is on the page. Files that were
  # sent, trashed or rescanned away drop out, so no later group can inherit a
  # choice made about a file it does not hold.
  defp prune_review_overrides(socket) do
    present =
      for {group, _reason, _detail} <- socket.assigns.refusals,
          file <- group.files,
          into: MapSet.new(),
          do: file.id

    overrides =
      Map.filter(socket.assigns.review_overrides, fn {id, _disposition} ->
        MapSet.member?(present, id)
      end)

    assign(socket, :review_overrides, overrides)
  end

  defp run_send(socket, ids, scope_label) do
    actor_id = to_string(socket.assigns.current_scope.user.id)
    result = Prune.send_to_review(ids, actor_id)

    socket
    |> maybe_flash_problems(result)
    |> maybe_set_review_run(result, scope_label)
    |> load_plan()
  end

  defp maybe_set_review_run(socket, %{returned: []}, _scope_label), do: socket

  defp maybe_set_review_run(socket, %{returned: returned}, scope_label) do
    assign(socket, :last_run, %{
      kind: :review,
      label: "Sent #{Components.file_count(length(returned))} #{scope_label} to Review"
    })
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
      kind: :trash,
      file_ids: Enum.map(trashed, & &1.id),
      label:
        "Trashed #{Components.file_count(length(trashed))} #{scope_label} " <>
          "(#{Components.humanize_bytes(bytes)})"
    })
  end
end
