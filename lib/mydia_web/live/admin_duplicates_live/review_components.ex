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

  This module calls `Components` for the shared display helpers and never the
  other way round, so the two do not depend on each other at compile time.
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
    <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 pt-2">
      <h2 class="text-lg font-semibold flex items-center gap-2">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5 opacity-60" /> Needs Attention
        <span class="badge badge-ghost">{length(@refusals)}</span>
      </h2>
      <div class="join">
        <button
          :if={@overridden?}
          id="duplicates-review-reset"
          type="button"
          class="btn btn-sm btn-ghost join-item"
          phx-click="reset_review_marks"
        >
          <.icon name="hero-arrow-path" class="w-4 h-4" /> Mark flagged
        </button>
        <button
          id="duplicates-review-selected"
          type="button"
          class="btn btn-sm btn-primary join-item"
          disabled={MapSet.size(@returning) == 0}
          phx-click="open_review_modal"
        >
          <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
          Send {Components.file_count(MapSet.size(@returning))} to Review
        </button>
      </div>
    </div>

    <p class="text-sm text-base-content/60">
      These are matching or scanning problems rather than duplicates. Files whose names don't
      match their item start on <span class="font-medium text-base-content">Review</span>.
      Sending a file to Review detaches it from the item, leaves it on disk, and holds it
      there until someone matches it. Every item always keeps at least one file.
    </p>

    <div class="bg-base-200 rounded-box divide-y divide-base-300">
      <.refusal_row
        :for={{group, reason, detail} <- @refusals}
        group={group}
        reason={reason}
        detail={detail}
        suspects={Map.get(@suspects, group.subject_id, MapSet.new())}
        returning={@returning}
      />
    </div>
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
    <div id="duplicates-review-modal" class="modal modal-open">
      <div class="modal-box">
        <div class="flex items-center gap-3 mb-5">
          <div class="w-10 h-10 rounded-xl bg-primary/20 flex items-center justify-center">
            <.icon name="hero-arrow-uturn-left" class="w-5 h-5 text-primary" />
          </div>
          <h3 class="font-bold text-lg">
            Send {Components.file_count(@count)} from {Components.item_count(@items)} to Review?
          </h3>
        </div>

        <p class="py-2">
          They stay on disk and wait in Review until someone matches them. Nothing is
          re-attached automatically.
        </p>

        <div class="modal-action mt-6 pt-4 border-t border-base-300">
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
        </div>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_review_modal"></div>
    </div>
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
    <div class="p-3 sm:p-4" id={"duplicates-refusal-#{@group.subject_id}"}>
      <div class="flex items-center gap-3">
        <div class="flex-1 min-w-0">
          <div class="font-medium truncate">{Components.subject_label(@group)}</div>
          <div class="text-xs opacity-60 truncate">
            {Components.file_count(length(@group.files))}
          </div>
        </div>
        <span class="badge badge-sm badge-outline badge-warning">{refusal_label(@reason)}</span>
        <span
          :if={@controls? and @returning_count > 0}
          class="badge badge-sm badge-outline hidden sm:inline-flex"
        >
          {@returning_count} to Review
        </span>
        <button
          :if={@controls?}
          id={"duplicates-review-group-#{@group.subject_id}"}
          type="button"
          class="btn btn-sm"
          disabled={@returning_count == 0}
          aria-label={"Send the marked files in #{Components.subject_label(@group)} to Review"}
          phx-click="send_group_to_review"
          phx-value-subject={@group.subject_id}
          phx-disable-with="Sending..."
        >
          <.icon name="hero-arrow-uturn-left" class="w-4 h-4" />
          Send {Components.file_count(@returning_count)} to Review
        </button>
      </div>

      <p class="text-sm text-base-content/60 mt-2">{refusal_explanation(@reason, @detail)}</p>

      <%= if @controls? do %>
        <div class="bg-base-100 rounded-box divide-y divide-base-300 mt-3">
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
        <ul class="text-xs opacity-60 list-disc pl-5 mt-1">
          <li :for={file <- @group.files}>{file.relative_path}</li>
        </ul>
      <% end %>
    </div>
    """
  end

  attr :file, :map, required: true
  attr :subject_id, :string, required: true
  attr :suspect?, :boolean, required: true
  attr :returning?, :boolean, required: true
  attr :last_left?, :boolean, required: true

  defp review_file_row(assigns) do
    relative_path = assigns.file.relative_path || ""

    assigns =
      assigns
      |> assign(:name, Path.basename(relative_path))
      |> assign(:folder, Components.folder_of(relative_path))

    ~H"""
    <div class="flex items-center gap-3 px-3 py-2">
      <div class="flex-1 min-w-0">
        <div class={["truncate text-sm", @returning? && "opacity-60"]}>{@name}</div>
        <div :if={@folder} class="truncate text-xs opacity-50">{@folder}</div>
      </div>

      <span
        :if={@suspect?}
        id={"duplicates-suspect-#{@file.id}"}
        class="badge badge-sm badge-warning badge-outline shrink-0"
      >
        Doesn't match
      </span>

      <%!-- Same shape as the Keep/Trash radiogroup in Components.file_row/1,
            and the same variable override recolours the checked Review option,
            for the reason given there. --%>
      <div
        class="join shrink-0"
        role="radiogroup"
        aria-label={"What to do with #{@file.relative_path}"}
      >
        <input
          type="radio"
          class="join-item btn btn-xs"
          id={"duplicates-leave-#{@file.id}"}
          name={"review-#{@file.id}"}
          aria-label="Leave"
          checked={not @returning?}
          phx-click="leave_file"
          phx-value-subject={@subject_id}
          phx-value-file={@file.id}
        />
        <input
          type="radio"
          class={[
            "join-item btn btn-xs",
            @returning? &&
              "[--btn-color:var(--color-warning)] [--btn-fg:var(--color-warning-content)]"
          ]}
          id={"duplicates-review-#{@file.id}"}
          name={"review-#{@file.id}"}
          aria-label="Review"
          checked={@returning?}
          disabled={@last_left?}
          phx-click="review_file"
          phx-value-subject={@subject_id}
          phx-value-file={@file.id}
        />
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
