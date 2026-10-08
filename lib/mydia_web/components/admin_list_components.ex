defmodule MydiaWeb.AdminListComponents do
  @moduledoc """
  The body of an admin page: section headings, the list container and its rows,
  the icon-only row action strip, the ENV badge, and the table variant for
  pages with many columns.

  These own the markup the admin page standard in
  `lib/mydia_web/components/README.md` describes, so pages stop copying class
  strings. Pages still own their events, assigns and forms.
  """
  use Phoenix.Component

  import MydiaWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :icon, :string, required: true
  attr :count, :integer, default: nil, doc: "shown as a ghost badge beside the title"
  slot :inner_block, required: true

  @doc "A real subsection of an admin page (Needs Attention, Scheduled Jobs)."
  def admin_section(assigns) do
    ~H"""
    <section id={@id} class="space-y-3">
      <h2 id={@id && "#{@id}-title"} class="text-lg font-semibold flex items-center gap-2">
        <.icon name={@icon} class="w-5 h-5 opacity-60" />
        {@title}
        <span :if={@count} class="badge badge-ghost">{@count}</span>
      </h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, required: true
  attr :items, :list, required: true
  slot :row, required: true, doc: "rendered once per item; use admin_row/1"
  slot :empty, required: true, doc: "text of the info alert shown when items is []"

  @doc """
  The standard list container, or the info alert when there is nothing to list.
  The container is `#<id>`, the alert `#<id>-empty`.
  """
  def admin_list(assigns) do
    ~H"""
    <div :if={@items == []} id={"#{@id}-empty"} class="alert alert-info">
      <.icon name="hero-information-circle" class="w-5 h-5" />
      <span>{render_slot(@empty)}</span>
    </div>
    <div :if={@items != []} id={@id} class="bg-base-200 rounded-box divide-y divide-base-300">
      <%= for item <- @items do %>
        {render_slot(@row, item)}
      <% end %>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :class, :string, default: nil, doc: "extra classes, e.g. opacity-60 for a disabled row"
  slot :title, required: true
  slot :descriptor, doc: "one line, truncated"

  slot :details,
    doc: "multi-line notes, warnings and sub-lists; below the descriptor, not truncated or dimmed"

  slot :badges, doc: "badge badge-sm badge-outline status badges"
  slot :actions, doc: "a row_actions/1 strip"

  @doc "One row of an admin_list/1: name and descriptor, then badges, then actions."
  def admin_row(assigns) do
    ~H"""
    <div id={@id} class={["p-3 sm:p-4", @class]}>
      <div class="flex flex-col sm:flex-row sm:items-center gap-3">
        <div class="flex-1 min-w-0">
          <div class="font-semibold flex items-center gap-2 flex-wrap [overflow-wrap:anywhere]">
            {render_slot(@title)}
          </div>
          <div :if={@descriptor != []} class="text-xs opacity-60 mt-1 truncate">
            {render_slot(@descriptor)}
          </div>
          <div :if={@details != []} class="mt-2 space-y-1 text-sm">{render_slot(@details)}</div>
        </div>
        <div :if={@badges != [] or @actions != []} class="flex flex-wrap items-center gap-2">
          {render_slot(@badges)}
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end

  slot :inner_block, required: true

  @doc "The row's action strip: a join of row_action/1 buttons, right-aligned on mobile."
  def row_actions(assigns) do
    ~H"""
    <div class="join ml-auto sm:ml-2">{render_slot(@inner_block)}</div>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true, doc: "tooltip and accessible name"
  attr :id, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :disabled_reason, :string, default: nil, doc: "tooltip explaining why it is disabled"
  attr :destructive, :boolean, default: false
  attr :loading, :boolean, default: false, doc: "spinner in place of the icon, disabled"
  attr :rest, :global, include: ~w(type)

  @doc """
  An icon-only action. With `disabled_reason` the button sits inside a
  `.tooltip` wrapper, because a disabled button fires no hover events of its
  own. `join-item` stays on the button, never the wrapper (see
  `MydiaWeb.SegmentedControl` on `.join-item > *` resetting the corners).
  """
  def row_action(assigns) do
    ~H"""
    <%= if @disabled and @disabled_reason do %>
      <div
        class="tooltip tooltip-left before:max-w-[12rem] sm:before:max-w-[20rem]"
        data-tip={@disabled_reason}
      >
        <.row_action_button {assigns} />
      </div>
    <% else %>
      <.row_action_button {assigns} />
    <% end %>
    """
  end

  defp row_action_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      class={["btn btn-sm btn-ghost join-item", @destructive && "text-error"]}
      title={@title}
      aria-label={@title}
      disabled={@disabled or @loading}
      {@rest}
    >
      <span :if={@loading} class="loading loading-spinner loading-xs"></span>
      <.icon
        :if={not @loading}
        name={@icon}
        class="w-4 h-4"
      />
    </button>
    """
  end

  attr :tip, :string, default: "Configured via environment variables (read-only)"

  @doc "Marks a row that comes from env or YAML and cannot be edited here."
  def env_lock_badge(assigns) do
    ~H"""
    <span class="badge badge-primary badge-xs tooltip gap-1" data-tip={@tip}>
      <.icon name="hero-lock-closed" class="w-3 h-3" /> ENV
    </span>
    """
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "fn row -> DOM id"

  slot :col, required: true do
    attr :label, :string
    attr :class, :string
  end

  slot :action, doc: "row_action/1 buttons for the row; wrapped in row_actions/1"
  slot :empty, required: true

  @doc """
  The table variant of admin_list/1, for pages with many rows and columns.
  Same empty state and the same icon-only actions.
  """
  def admin_table(assigns) do
    ~H"""
    <div :if={@rows == []} id={"#{@id}-empty"} class="alert alert-info">
      <.icon name="hero-information-circle" class="w-5 h-5" />
      <span>{render_slot(@empty)}</span>
    </div>
    <div
      :if={@rows != []}
      id={@id}
      class="overflow-x-auto rounded-box border border-base-300 bg-base-100"
    >
      <table class="table table-zebra">
        <thead>
          <tr>
            <th :for={col <- @col} class={col[:class]}>{col[:label]}</th>
            <th :if={@action != []}><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
            <td :for={col <- @col} class={col[:class]}>{render_slot(col, row)}</td>
            <td :if={@action != []} class="text-right">
              <.row_actions>{render_slot(@action, row)}</.row_actions>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
