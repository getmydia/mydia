defmodule MydiaWeb.DownloadsLive.ListComponents do
  @moduledoc """
  Downloads page chrome: the stats bar, the search and filter bar, the active
  filter chips, the client chip that opens a client's web UI, and the row
  action strip shared by the list and the detail drawer.
  """
  use MydiaWeb, :html

  import MydiaWeb.DownloadsLive.Format
  import MydiaWeb.Formatters

  alias MydiaWeb.DownloadsLive.{Filters, ListView, Summary}
  alias Phoenix.LiveView.JS

  attr :summary, Summary, required: true

  def stats_bar(assigns) do
    ~H"""
    <div
      :if={@summary.active > 0}
      id="downloads-stats"
      class="stats stats-vertical sm:stats-horizontal w-full bg-base-100 shadow mb-4"
    >
      <div class="stat py-3">
        <div class="stat-figure text-primary">
          <.icon name="hero-arrow-down-tray" class="size-6" />
        </div>
        <div class="stat-title">Active</div>
        <div class="stat-value text-2xl tabular-nums">{@summary.active}</div>
        <div :if={@summary.stalled > 0} id="downloads-stats-stalled" class="stat-desc text-warning">
          {@summary.stalled} stalled
        </div>
        <div :if={@summary.stalled == 0} class="stat-desc">in the queue</div>
      </div>
      <div class="stat py-3">
        <div class="stat-figure text-info"><.icon name="hero-arrow-down" class="size-6" /></div>
        <div class="stat-title">Download</div>
        <div class="stat-value text-2xl tabular-nums">{format_speed(@summary.download_speed)}</div>
        <div :if={@summary.stale_as_of} class="stat-desc">
          as of {format_relative_time(@summary.stale_as_of)}
        </div>
      </div>
      <div class="stat py-3">
        <div class="stat-figure text-success"><.icon name="hero-arrow-up" class="size-6" /></div>
        <div class="stat-title">Upload</div>
        <div class="stat-value text-2xl tabular-nums">{format_speed(@summary.upload_speed)}</div>
      </div>
      <div class="stat py-3">
        <div class="stat-figure text-secondary">
          <.icon name="hero-circle-stack" class="size-6" />
        </div>
        <div class="stat-title">Remaining</div>
        <div class="stat-value text-2xl tabular-nums">
          {format_file_size(@summary.remaining_bytes)}
        </div>
        <div class="stat-desc">
          {if @summary.eta_seconds,
            do: "done in #{format_eta(@summary.eta_seconds)}",
            else: "no estimate"}
        </div>
      </div>
    </div>
    """
  end

  attr :filters, Filters, required: true
  attr :clients, :list, required: true
  attr :tab, :atom, required: true

  def filter_bar(assigns) do
    assigns = assign(assigns, :status_options, ListView.status_options())

    ~H"""
    <form
      id="downloads-filter-form"
      phx-change="filter"
      phx-submit="filter"
      class="flex flex-wrap items-center gap-2 mb-3"
    >
      <label class="input input-sm w-full sm:w-72">
        <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
        <input
          id="downloads-search"
          type="search"
          name="q"
          value={@filters.q}
          placeholder="Search downloads"
          aria-label="Search downloads"
          autocomplete="off"
          phx-debounce="300"
          phx-hook=".FocusSearch"
          class="grow"
        />
        <kbd class="kbd kbd-sm hidden sm:inline-flex">/</kbd>
      </label>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".FocusSearch">
        export default {
          mounted() {
            this.onKey = (e) => {
              if (e.key !== "/" || e.metaKey || e.ctrlKey || e.altKey) return;
              if (e.target.closest("input, textarea, select, [contenteditable]")) return;
              e.preventDefault();
              this.el.focus();
            };
            window.addEventListener("keydown", this.onKey);
          },
          destroyed() {
            window.removeEventListener("keydown", this.onKey);
          },
        };
      </script>

      <input
        :if={length(@clients) <= 1 and @filters.client}
        type="hidden"
        name="client"
        value={@filters.client}
      />
      <select
        :if={length(@clients) > 1}
        id="downloads-client-filter"
        name="client"
        class="select select-sm w-full sm:w-auto"
        aria-label="Download client"
      >
        <option value="">All clients</option>
        <option :for={client <- @clients} value={client} selected={@filters.client == client}>
          {client}
        </option>
      </select>

      <div :if={@tab == :queue} id="downloads-status-filter" class="filter">
        <input
          class="btn btn-sm filter-reset"
          type="radio"
          name="status"
          value=""
          aria-label="All"
          checked={is_nil(@filters.status)}
        />
        <input
          :for={{value, label} <- @status_options}
          id={"downloads-status-#{value}"}
          class="btn btn-sm"
          type="radio"
          name="status"
          value={value}
          aria-label={label}
          checked={@filters.status == value}
        />
      </div>
    </form>
    """
  end

  attr :filters, Filters, required: true

  def active_filters(assigns) do
    ~H"""
    <div
      :if={ListView.active?(@filters)}
      id="downloads-active-filters"
      class="flex flex-wrap items-center gap-2 mb-3"
    >
      <span
        :for={{key, label} <- ListView.chips(@filters)}
        id={"downloads-filter-chip-#{key}"}
        class="badge badge-outline badge-sm gap-1"
      >
        {label}
        <button
          type="button"
          class="cursor-pointer opacity-60 hover:opacity-100"
          phx-click="remove_filter"
          phx-value-key={key}
          aria-label={"Remove filter #{label}"}
        >
          <.icon name="hero-x-mark" class="size-3" />
        </button>
      </span>
      <button
        type="button"
        id="downloads-clear-filters"
        class="btn btn-link btn-xs"
        phx-click="clear_filters"
      >
        Clear filters
      </button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :url, :string, default: nil

  def client_chip(assigns) do
    ~H"""
    <%= if @url do %>
      <span class="tooltip" data-tip={"Open #{@name}"}>
        <a
          id={@id}
          href={@url}
          target="_blank"
          rel="noopener noreferrer"
          class="badge badge-ghost badge-sm gap-1 hover:badge-outline transition-colors"
        >
          <.icon name="hero-server" class="size-3 opacity-70" />
          {@name}
          <.icon name="hero-arrow-top-right-on-square" class="size-3 opacity-70" />
        </a>
      </span>
    <% else %>
      <span id={@id} class="badge badge-ghost badge-sm gap-1">
        <.icon name="hero-server" class="size-3 opacity-70" />
        {@name}
      </span>
    <% end %>
    """
  end

  attr :download, :map, required: true
  attr :tab, :atom, required: true

  attr :context, :string,
    default: "row",
    doc: "\"row\" or \"drawer\"; prefixes ids and hides Details in the drawer"

  @doc """
  The action strip for one download: a `join` of icon buttons, with rarer
  actions in an "Actions" dropdown beside it (see
  lib/mydia_web/components/README.md on row actions and dropdown stacking).
  """
  def download_actions(assigns) do
    ~H"""
    <div :if={@tab in [:queue, :completed]} class="flex items-center gap-2 shrink-0">
      <.row_actions>
        <.row_action
          :if={@context == "row"}
          id={"download-details-#{@download.id}"}
          icon="hero-information-circle"
          title="Details"
          phx-click="open_details"
          phx-value-id={@download.id}
        />
        <%= if @tab == :queue do %>
          <.row_action
            :if={@download.status == "paused"}
            id={"#{@context}-resume-#{@download.id}"}
            icon="hero-play"
            title="Resume download"
            phx-click="resume_download"
            phx-value-id={@download.id}
          />
          <.row_action
            :if={@download.status != "paused"}
            id={"#{@context}-pause-#{@download.id}"}
            icon="hero-pause"
            title="Pause download"
            phx-click="pause_download"
            phx-value-id={@download.id}
          />
          <.row_action
            id={"#{@context}-cancel-#{@download.id}"}
            icon="hero-x-mark"
            title="Cancel download"
            destructive
            phx-click="cancel_download"
            phx-value-id={@download.id}
            data-confirm="Cancel this download?"
          />
        <% else %>
          <.row_action
            :if={is_nil(@download.match_status) and @download.rematch_eligible?}
            id={"#{@context}-rematch-#{@download.id}"}
            icon="hero-arrow-path"
            title="Re-match to the correct title"
            phx-click="open_match_modal"
            phx-value-id={@download.id}
            phx-value-mode="postimport"
          />
          <.row_action
            id={"#{@context}-clear-#{@download.id}"}
            icon="hero-trash"
            title="Clear completed download"
            destructive
            phx-click="clear_single_completed"
            phx-value-id={@download.id}
            data-confirm="Remove from client and clear from history?"
          />
        <% end %>
      </.row_actions>

      <div :if={@tab == :queue} class="dropdown dropdown-end z-20">
        <div
          tabindex="0"
          role="button"
          class="btn btn-sm btn-ghost btn-square"
          aria-label="More actions"
        >
          <.icon name="hero-ellipsis-vertical" class="size-4" />
        </div>
        <ul tabindex="0" class="dropdown-content menu bg-base-200 rounded-box w-48 p-2 shadow">
          <li>
            <button
              type="button"
              id={"#{@context}-change-match-#{@download.id}"}
              phx-click={
                JS.push("open_match_modal", value: %{id: @download.id, mode: "inflight"})
                |> JS.dispatch("mydia:blur")
              }
            >
              <.icon name="hero-pencil-square" class="size-4" /> Change match
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
