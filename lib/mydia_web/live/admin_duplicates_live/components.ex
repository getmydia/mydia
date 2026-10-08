defmodule MydiaWeb.AdminDuplicatesLive.Components do
  @moduledoc """
  Function components for the duplicates review page. Used only by the sibling
  LiveView.

  Every file row carries one control: a Keep/Trash pair of radios in a `join`,
  so the row states its current disposition in words and the alternative sits
  next to it. An earlier revision paired an unlabelled keeper radio on the
  left with an unlabelled red checkbox on the right, which left an operator
  with two controls, no labels, and no way to tell which one decided the
  file's fate.

  Each group carries two buttons rather than one that swaps meaning: a marking
  toggle, and a button that actually trashes. The marking half still swaps its
  label so the row never goes dead once everything in it is kept.
  """

  use MydiaWeb, :html

  import MydiaWeb.Formatters, only: [format_file_size: 1]

  alias Mydia.Library.MediaFile

  @doc """
  Renders the Duplicates section of the page.

  Below the decisions come the Needs Attention section
  (`MydiaWeb.AdminDuplicatesLive.ReviewComponents.needs_attention/1`, shown only
  when something was refused) and the Misfiled live component.
  """
  attr :decisions, :list, required: true
  attr :refusals, :list, required: true
  attr :selected, :any, required: true
  attr :retention_days, :integer, required: true
  attr :suspects, :map, required: true
  attr :returning, :any, required: true
  attr :overridden?, :boolean, required: true
  attr :current_scope, :any, required: true

  def duplicates_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <p class="text-sm text-base-content/60">
        Items holding more than one file, where every copy is proven to be the same content.
        Each file is set to either <span class="font-medium text-base-content">Keep</span>
        or <span class="font-medium text-error">Trash</span>; the best copy is listed first and
        kept, the rest are already marked for trash. Trash one item with its own button, or
        every item with the button above. Every item always keeps at least one file. Trashed
        files are held for {@retention_days} days before permanent deletion, and a run can be
        undone until you leave this page.
      </p>

      <.admin_list id="duplicates-groups" items={@decisions}>
        <:row :let={decision}>
          <.decision_row decision={decision} selected={@selected} />
        </:row>
        <:empty>
          <%= if @refusals == [] do %>
            No item holds more than one file. There are no duplicates to review.
          <% else %>
            Nothing can be trashed safely right now. Every item below needs attention first.
          <% end %>
        </:empty>
      </.admin_list>

      <MydiaWeb.AdminDuplicatesLive.ReviewComponents.needs_attention
        :if={@refusals != []}
        refusals={@refusals}
        suspects={@suspects}
        returning={@returning}
        overridden?={@overridden?}
      />

      <.live_component
        module={MydiaWeb.AdminDuplicatesLive.MisfiledComponent}
        id="misfiled"
        current_scope={@current_scope}
      />
    </div>
    """
  end

  @doc "The page header's bulk trash buttons."
  attr :decisions, :list, required: true
  attr :selected, :any, required: true
  attr :reclaimable, :integer, required: true

  def header_actions(assigns) do
    total_losers =
      Enum.reduce(assigns.decisions, 0, fn decision, acc -> acc + length(decision.losers) end)

    assigns = assign(assigns, :all_selected?, MapSet.size(assigns.selected) == total_losers)

    ~H"""
    <div class="join">
      <button
        :if={not @all_selected?}
        id="duplicates-trash-all"
        type="button"
        class="btn btn-sm btn-ghost join-item"
        phx-click="trash_all_duplicates"
      >
        <.icon name="hero-check-circle" class="w-4 h-4" /> Mark all for trash
      </button>
      <button
        id="duplicates-trash-selected"
        type="button"
        class="btn btn-sm btn-error join-item"
        disabled={MapSet.size(@selected) == 0}
        phx-click="open_trash_modal"
      >
        <.icon name="hero-trash" class="w-4 h-4" />
        Trash {file_count(MapSet.size(@selected))} ({format_file_size(@reclaimable)})
      </button>
    </div>
    """
  end

  attr :decision, :map, required: true
  attr :selected, :any, required: true

  defp decision_row(assigns) do
    selected = assigns.selected
    marked = Enum.filter(assigns.decision.losers, &MapSet.member?(selected, &1.id))

    assigns =
      assigns
      |> assign(:selected_count, length(marked))
      |> assign(:selected_bytes, Enum.reduce(marked, 0, &(&2 + (&1.size || 0))))
      |> assign(:files, [assigns.decision.keeper | assigns.decision.losers])

    ~H"""
    <.admin_row id={"duplicates-group-#{@decision.group.subject_id}"}>
      <:title>{subject_label(@decision.group)}</:title>
      <:descriptor>{@decision.reason}</:descriptor>
      <:badges>
        <span class="badge badge-sm badge-outline">{file_count(length(@files))}</span>
        <span :if={@selected_count > 0} class="badge badge-sm badge-outline badge-error">
          {@selected_count} to trash · {format_file_size(@selected_bytes)}
        </span>
        <span :if={@selected_count == 0} class="badge badge-sm badge-outline">Keeping all</span>
      </:badges>
      <:actions>
        <.row_actions>
          <.row_action
            id={"duplicates-group-mark-#{@decision.group.subject_id}"}
            icon="hero-check-circle"
            title={if @selected_count > 0, do: "Keep all", else: "Mark all for trash"}
            phx-click={if @selected_count > 0, do: "keep_group", else: "trash_group"}
            phx-value-subject={@decision.group.subject_id}
          />
          <.row_action
            id={"duplicates-group-trash-#{@decision.group.subject_id}"}
            icon="hero-trash"
            destructive
            title={"Trash #{file_count(@selected_count)} (#{format_file_size(@selected_bytes)})"}
            disabled={@selected_count == 0}
            phx-click="trash_group_now"
            phx-value-subject={@decision.group.subject_id}
            phx-disable-with="Trashing..."
          />
        </.row_actions>
      </:actions>
      <:body>
        <div class="bg-base-100 rounded-box divide-y divide-base-300">
          <.file_row
            :for={file <- @files}
            file={file}
            subject_id={@decision.group.subject_id}
            trashing?={MapSet.member?(@selected, file.id)}
            best?={file.id == @decision.keeper.id}
          />
        </div>
      </:body>
    </.admin_row>
    """
  end

  attr :file, :map, required: true
  attr :subject_id, :string, required: true
  attr :trashing?, :boolean, required: true
  attr :best?, :boolean, required: true

  defp file_row(assigns) do
    assigns =
      assigns
      |> assign(:name, Path.basename(assigns.file.relative_path))
      |> assign(:folder, folder_of(assigns.file.relative_path))

    ~H"""
    <div class="flex items-center gap-3 px-3 py-2">
      <div class="flex-1 min-w-0">
        <%!--
        The filename, not the whole relative path. Copies of one item share a
        folder and differ in the tail of their name ("...1080p.BluRay.x265"),
        which is exactly what a truncated path column cuts off first, leaving
        an operator three rows they cannot tell apart.
        --%>
        <div class={["truncate text-sm", @trashing? && "line-through opacity-50"]}>{@name}</div>
        <div :if={@folder} class="truncate text-xs opacity-50">{@folder}</div>
      </div>

      <span :if={@best? and not @trashing?} class="badge badge-sm badge-ghost hidden sm:inline-flex">
        Best copy
      </span>
      <span class="badge badge-ghost badge-sm">{quality_label(@file)}</span>
      <span class="text-xs opacity-60 whitespace-nowrap">{format_file_size(@file.size)}</span>

      <%!--
      One radiogroup per file, not a checkbox: the two options are named on
      screen, so the row reads as a state ("this file is set to Keep") and the
      other half of the pair reads as the action. daisyUI renders the
      aria-label of an input styled `.btn` as its text.
      --%>
      <div
        class="join shrink-0"
        role="radiogroup"
        aria-label={"Disposition for #{@file.relative_path}"}
      >
        <input
          type="radio"
          class="join-item btn btn-xs"
          id={"duplicates-keep-#{@file.id}"}
          name={"disposition-#{@file.id}"}
          aria-label="Keep"
          checked={not @trashing?}
          phx-click="keep_file"
          phx-value-subject={@subject_id}
          phx-value-file={@file.id}
        />
        <%!--
        `btn-error` and `checked:btn-error` both lose to daisyUI's own
        "a checked .btn is primary" rule, which sits in the outer
        `daisyui.l1` cascade layer and so outranks every colour class in the
        nested layers no matter how specific. Setting the variables that rule
        writes is the way to recolour it: an arbitrary property lands outside
        daisyUI's layers entirely.
        --%>
        <input
          type="radio"
          class={[
            "join-item btn btn-xs",
            @trashing? && "[--btn-color:var(--color-error)] [--btn-fg:var(--color-error-content)]"
          ]}
          id={"duplicates-trash-#{@file.id}"}
          name={"disposition-#{@file.id}"}
          aria-label="Trash"
          checked={@trashing?}
          phx-click="trash_file"
          phx-value-subject={@subject_id}
          phx-value-file={@file.id}
        />
      </div>
    </div>
    """
  end

  @doc """
  The library-relative folder for a file, or nil when the file sits at the root
  of its library path and there is nothing useful to show. Public because the
  Needs Attention rows in `MydiaWeb.AdminDuplicatesLive.ReviewComponents` show
  files the same way.
  """
  def folder_of(relative_path) do
    case Path.dirname(relative_path) do
      "." -> nil
      "/" -> nil
      folder -> folder
    end
  end

  @doc """
  Renders the trash confirmation modal.

  A `data-confirm` would be enough for a single row, but this button moves
  every file marked for trash across the whole library in one go. The blast
  radius (files, items, bytes) is worth showing before it runs.
  """
  attr :count, :integer, required: true
  attr :items, :integer, required: true
  attr :bytes, :integer, required: true
  attr :retention_days, :integer, required: true

  def trash_confirm_modal(assigns) do
    ~H"""
    <.admin_modal
      id="duplicates-confirm-modal"
      tone={:error}
      icon="hero-trash"
      title={"Trash #{file_count(@count)}?"}
      subtitle={"Across #{item_count(@items)}, reclaiming #{format_file_size(@bytes)}."}
      on_close="close_trash_modal"
    >
      <p class="py-2">
        Every file marked for trash is a redundant copy of one set to Keep, so each item keeps
        a playable file. Trashed files are held for {@retention_days} days before permanent
        deletion.
      </p>
      <:actions>
        <button
          id="duplicates-cancel"
          type="button"
          class="btn btn-ghost"
          phx-click="close_trash_modal"
        >
          Cancel
        </button>
        <button
          id="duplicates-confirm"
          type="button"
          class="btn btn-error"
          phx-click="confirm_trash"
          phx-disable-with="Trashing..."
        >
          <.icon name="hero-trash" class="w-4 h-4" /> Move to trash
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  @doc """
  The toast for a completed run on this page.

  A trash run (`kind: :trash`) offers Undo, which `Mydia.Library.Prune.undo/2`
  honors until the page is left. A send to Review (`kind: :review`) has no undo
  of its own, since `/review` can reattach any file it sent, so it links there
  instead.

  This cannot be a flash. `core_components.ex` puts
  `phx-click="lv:clear-flash"` on the whole flash container, which would
  swallow a nested button or link, and flash values are strings, so the file
  ids would need an assign regardless.

  It sits bottom-end because the flash group sits top-end, and a partial run
  shows both: an error flash for what could not move, and this for what did.

  There is no auto-dismiss timer. Any interval is a guess, and an operator
  reading filenames to check they trashed the right copy will lose that race.

  The DOM ids keep their `duplicates-undo` prefix from when this was only the
  undo toast; tests select on them.
  """
  attr :run, :map, required: true

  def run_toast(assigns) do
    ~H"""
    <div id="duplicates-undo-toast" class="toast toast-bottom toast-end z-50" role="status">
      <div class="alert alert-success w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap">
        <.icon name="hero-check-circle" class="size-5 shrink-0" />
        <span class="text-sm">{@run.label}</span>
        <div class="flex-1" />
        <button
          :if={@run.kind == :trash}
          id="duplicates-undo"
          type="button"
          class="btn btn-sm btn-ghost"
          phx-click="undo_trash"
          phx-disable-with="Undoing..."
        >
          <.icon name="hero-arrow-uturn-left" class="w-4 h-4" /> Undo
        </button>
        <.link
          :if={@run.kind == :review}
          id="duplicates-open-review"
          navigate={~p"/review"}
          class="btn btn-sm btn-ghost"
        >
          <.icon name="hero-inbox-arrow-down" class="w-4 h-4" /> Open Review
        </.link>
        <button
          id="duplicates-undo-dismiss"
          type="button"
          class="group self-start cursor-pointer"
          aria-label="Dismiss"
          phx-click="dismiss_undo"
        >
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The operator-facing name of a group's subject. Public because the LiveView
  builds the undo toast's label from it, and a movie title or a
  "Show S01E02" string is a display concern that belongs here rather than
  duplicated in the page module.
  """
  def subject_label(%{subject_type: :movie, subject: movie}), do: movie.title

  def subject_label(%{subject_type: :episode, subject: episode, media_item: show}) do
    "#{show.title} S#{pad(episode.season_number)}E#{pad(episode.episode_number)}"
  end

  defp pad(nil), do: "??"
  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp quality_label(%MediaFile{} = file) do
    [file.resolution, file.codec] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  @doc """
  Pluralized counts. Public because the page template calls it: the page
  module builds the undo toast's label and must count files and items the same
  way the rows above it do.
  """
  def file_count(1), do: "1 file"
  def file_count(n), do: "#{n} files"

  def item_count(1), do: "1 item"
  def item_count(n), do: "#{n} items"
end
