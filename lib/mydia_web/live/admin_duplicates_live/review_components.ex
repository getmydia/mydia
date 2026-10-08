defmodule MydiaWeb.AdminDuplicatesLive.ReviewComponents do
  @moduledoc """
  The Needs Attention section of the duplicates page. Used only by the sibling
  LiveView.

  Every group here was refused by `Mydia.Library.Prune.Eligibility`, which in
  practice mostly means a file filed against the wrong item. The fix for that
  is to send the stray file to Review, so each file row carries a Leave/Review
  pair of radios, styled like the Keep/Trash pair in
  `MydiaWeb.AdminDuplicatesLive.Components`. The LiveView decides which files
  are bound for Review and hands the set down as `returning`; files
  `Eligibility.suspect_files/1` names carry a "Doesn't match" badge.

  `:duplicate_registration` groups get no controls. Both of their rows point at
  one path, and the fix there is a rescan.

  This module calls `Components` for the shared display helpers. `Components`
  only renders `needs_attention/1` from its tab template, a runtime call, so
  the two do not depend on each other at compile time.
  """

  use MydiaWeb, :html

  alias MydiaWeb.AdminDuplicatesLive.Components

  @doc """
  Renders the Needs Attention section: a header, an explanation, and one row
  per refused group.
  """
  attr :refusals, :list, required: true
  attr :suspects, :map, required: true
  attr :returning, :any, required: true
  attr :overridden?, :boolean, required: true

  def needs_attention(assigns) do
    ~H"""
    <.admin_section
      id="duplicates-needs-attention"
      title="Needs Attention"
      icon="hero-exclamation-triangle"
      count={length(@refusals)}
    >
      <:actions>
        <button
          :if={@overridden?}
          id="duplicates-review-reset"
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click="reset_review_marks"
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /> Mark flagged
        </button>
        <button
          id="duplicates-review-selected"
          type="button"
          class="btn btn-sm btn-primary"
          disabled={MapSet.size(@returning) == 0}
          phx-click="open_review_modal"
        >
          <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
          Send {Components.file_count(MapSet.size(@returning))} to Review
        </button>
      </:actions>

      <p class="text-sm text-base-content/60">
        These are matching or scanning problems rather than duplicates. Files whose names don't
        match their item start on <span class="font-medium text-base-content">Review</span>.
        Sending a file to Review detaches it from the item, leaves it on disk, and holds it
        there until someone matches it. Every item always keeps at least one file.
      </p>

      <.admin_list id="duplicates-refusals" items={@refusals}>
        <:row :let={{group, reason, detail}}>
          <.refusal_row
            group={group}
            reason={reason}
            detail={detail}
            suspects={Map.get(@suspects, group.subject_id, MapSet.new())}
            returning={@returning}
          />
        </:row>
        <:empty>Nothing needs attention.</:empty>
      </.admin_list>
    </.admin_section>
    """
  end

  @doc """
  Confirms a page-level send to Review.

  The per-group button needs no confirmation, but this one detaches every
  marked file across the whole section in one go, so the scope is worth a
  click. Nothing is destroyed, which is why the copy talks about where the
  files go rather than warning.
  """
  attr :count, :integer, required: true
  attr :items, :integer, required: true

  def review_confirm_modal(assigns) do
    ~H"""
    <.admin_modal
      id="duplicates-review-modal"
      icon="hero-arrow-uturn-left"
      title={"Send #{Components.file_count(@count)} from #{Components.item_count(@items)} to Review?"}
      on_close="close_review_modal"
    >
      <p class="py-2">
        They stay on disk and wait in Review until someone matches them. Nothing is
        re-attached automatically.
      </p>
      <:actions>
        <button
          id="duplicates-review-cancel"
          type="button"
          class="btn btn-ghost"
          phx-click="close_review_modal"
        >
          Cancel
        </button>
        <button
          id="duplicates-review-confirm"
          type="button"
          class="btn btn-primary"
          phx-click="confirm_review"
          phx-disable-with="Sending..."
        >
          <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> Send to Review
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  attr :group, :map, required: true
  attr :reason, :atom, required: true
  attr :detail, :map, required: true
  attr :suspects, :any, required: true
  attr :returning, :any, required: true

  defp refusal_row(assigns) do
    files = assigns.group.files
    returning_count = Enum.count(files, &MapSet.member?(assigns.returning, &1.id))

    assigns =
      assigns
      |> assign(:controls?, assigns.reason != :duplicate_registration)
      |> assign(:returning_count, returning_count)
      |> assign(:left_count, length(files) - returning_count)

    ~H"""
    <.admin_row id={"duplicates-refusal-#{@group.subject_id}"}>
      <:title>{Components.subject_label(@group)}</:title>
      <:descriptor>{Components.file_count(length(@group.files))}</:descriptor>
      <:details>
        <p class="text-base-content/60">{refusal_explanation(@reason, @detail)}</p>
      </:details>
      <:badges>
        <span class="badge badge-sm badge-outline badge-warning">{refusal_label(@reason)}</span>
        <span :if={@controls? and @returning_count > 0} class="badge badge-sm badge-outline">
          {@returning_count} to Review
        </span>
      </:badges>
      <:actions>
        <.row_actions :if={@controls?}>
          <.row_action
            id={"duplicates-review-group-#{@group.subject_id}"}
            icon="hero-arrow-uturn-left"
            title={"Send #{Components.file_count(@returning_count)} to Review"}
            disabled={@returning_count == 0}
            phx-click="send_group_to_review"
            phx-value-subject={@group.subject_id}
            phx-disable-with="Sending..."
          />
        </.row_actions>
      </:actions>
      <:body>
        <%= if @controls? do %>
          <div class="bg-base-100 rounded-box divide-y divide-base-300">
            <.review_file_row
              :for={file <- @group.files}
              file={file}
              subject_id={@group.subject_id}
              suspect?={MapSet.member?(@suspects, file.id)}
              returning?={MapSet.member?(@returning, file.id)}
              last_left?={@left_count == 1 and not MapSet.member?(@returning, file.id)}
            />
          </div>
        <% else %>
          <ul class="text-xs opacity-60 list-disc pl-5">
            <li :for={file <- @group.files}>{file.relative_path}</li>
          </ul>
        <% end %>
      </:body>
    </.admin_row>
    """
  end

  @doc """
  One file with a Leave/Review radio pair. Shared with
  `MydiaWeb.AdminDuplicatesLive.MisfiledComponent`, which passes its own
  `id_prefix` (a file can appear in both sections at once) and its `target`.
  """
  attr :file, :map, required: true
  attr :subject_id, :string, required: true
  attr :suspect?, :boolean, required: true
  attr :returning?, :boolean, required: true
  attr :last_left?, :boolean, required: true
  attr :id_prefix, :string, default: "duplicates"
  attr :target, :any, default: nil
  attr :suspect_label, :string, default: "Doesn't match"

  def review_file_row(assigns) do
    relative_path = assigns.file.relative_path || ""

    path_label =
      if relative_path != "", do: relative_path, else: "file #{assigns.file.id}"

    assigns =
      assigns
      |> assign(:name, Path.basename(relative_path))
      |> assign(:folder, Components.folder_of(relative_path))
      |> assign(:path_label, path_label)

    ~H"""
    <div class="flex items-center gap-3 px-3 py-2 flex-wrap">
      <div class="basis-full sm:basis-auto sm:flex-1 min-w-0">
        <div class={["truncate text-sm", @returning? && "opacity-60"]}>{@name}</div>
        <div :if={@folder} class="truncate text-xs opacity-50">{@folder}</div>
      </div>

      <%!-- Wrapped so the name above keeps a full line at phone width: the
            basis-full text block fills the row and pushes this group to a
            line of its own, where ml-auto right-aligns it. --%>
      <div class="flex items-center gap-3 ml-auto sm:ml-0">
        <span
          :if={@suspect?}
          id={"#{@id_prefix}-suspect-#{@file.id}"}
          class="badge badge-sm badge-warning badge-outline shrink-0"
        >
          {@suspect_label}
        </span>

        <%!-- Same shape as the Keep/Trash radiogroup in Components.file_row/1,
              and the same variable override recolours the checked Review option,
              for the reason given there. --%>
        <div
          class="join shrink-0"
          role="radiogroup"
          aria-label={"What to do with #{@path_label}"}
        >
          <input
            type="radio"
            class="join-item btn btn-xs"
            id={"#{@id_prefix}-leave-#{@file.id}"}
            name={"#{@id_prefix}-review-#{@file.id}"}
            aria-label="Leave"
            checked={not @returning?}
            phx-click="leave_file"
            phx-value-subject={@subject_id}
            phx-value-file={@file.id}
            phx-target={@target}
          />
          <input
            type="radio"
            class={[
              "join-item btn btn-xs",
              @returning? &&
                "[--btn-color:var(--color-warning)] [--btn-fg:var(--color-warning-content)]"
            ]}
            id={"#{@id_prefix}-review-#{@file.id}"}
            name={"#{@id_prefix}-review-#{@file.id}"}
            aria-label="Review"
            checked={@returning?}
            disabled={@last_left?}
            phx-click="review_file"
            phx-value-subject={@subject_id}
            phx-value-file={@file.id}
            phx-target={@target}
          />
        </div>
      </div>
    </div>
    """
  end

  # Moved verbatim from Components, which no longer renders refusals.
  defp refusal_label(:duplicate_registration), do: "Registered twice"
  defp refusal_label(:unanalyzed), do: "Not analyzed"
  defp refusal_label(:duration_mismatch), do: "Different lengths"
  defp refusal_label(:name_mismatch), do: "Names disagree"
  defp refusal_label(:episode_mismatch), do: "Wrong episode"
  defp refusal_label(:nothing_to_prune), do: "Nothing to trash"

  defp refusal_explanation(:duplicate_registration, detail) do
    "One file on disk is registered twice (#{detail.path}). Trashing a copy would move the only real file. Rescan this library path instead."
  end

  defp refusal_explanation(:unanalyzed, detail) do
    "#{detail.unanalyzed_count} file(s) have no duration, so they cannot be compared. Run analysis first."
  end

  defp refusal_explanation(:duration_mismatch, detail) do
    "These files are #{percent(detail.spread)} apart in length, more than the #{percent(detail.tolerance)} allowed, so they are not the same content. This is usually bonus features or a file matched to the wrong item."
  end

  defp refusal_explanation(:name_mismatch, _detail) do
    "At least one filename does not belong to this item. Fix the match before trashing anything."
  end

  defp refusal_explanation(:episode_mismatch, _detail) do
    "At least one filename names a different episode than the one it is attached to."
  end

  defp refusal_explanation(:nothing_to_prune, _detail), do: "Only one file remains."

  # Formats a fraction (0.093) as a percentage string ("9.3%") for the
  # duration mismatch explanation.
  defp percent(fraction), do: "#{Float.round(fraction * 100, 1)}%"
end
