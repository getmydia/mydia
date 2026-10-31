defmodule MydiaWeb.DownloadsLive.ListComponents do
  @moduledoc """
  Downloads page chrome: the tab bar, the stats bar, the search and filter bar,
  the active filter chips, the empty state, the client chip that opens a
  client's web UI, and the row action strip shared by the list and the detail
  drawer.
  """
  use MydiaWeb, :html

  import MydiaWeb.DownloadsLive.Format
  import MydiaWeb.Formatters

  alias MydiaWeb.DownloadsLive.{Filters, ListView, Summary, Tab}
  alias MydiaWeb.SeedingComponents
  alias Phoenix.LiveView.JS

  attr :summary, Summary, required: true
  attr :display, Mydia.TimeDisplay, required: true

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
        <div class="stat-title">{pgettext("download", "Active")}</div>
        <div class="stat-value text-2xl tabular-nums">{@summary.active}</div>
        <div :if={@summary.stalled > 0} id="downloads-stats-stalled" class="stat-desc text-warning">
          {ngettext("%{count} stalled", "%{count} stalled", @summary.stalled)}
        </div>
        <div :if={@summary.stalled == 0} class="stat-desc">{gettext("in the queue")}</div>
      </div>
      <div class="stat py-3">
        <div class="stat-figure text-info"><.icon name="hero-arrow-down" class="size-6" /></div>
        <div class="stat-title">{pgettext("download speed", "Download")}</div>
        <div class="stat-value text-2xl tabular-nums">{format_speed(@summary.download_speed)}</div>
        <div :if={@summary.stale_as_of} class="stat-desc">
          {gettext("as of %{time}", time: format_relative_time(@summary.stale_as_of, @display))}
        </div>
      </div>
      <div class="stat py-3">
        <div class="stat-figure text-success"><.icon name="hero-arrow-up" class="size-6" /></div>
        <div class="stat-title">{pgettext("upload speed", "Upload")}</div>
        <div class="stat-value text-2xl tabular-nums">{format_speed(@summary.upload_speed)}</div>
      </div>
      <div class="stat py-3">
        <div class="stat-figure text-secondary">
          <.icon name="hero-circle-stack" class="size-6" />
        </div>
        <div class="stat-title">{gettext("Remaining")}</div>
        <div class="stat-value text-2xl tabular-nums">
          {format_file_size(@summary.remaining_bytes)}
        </div>
        <div class="stat-desc">
          {if @summary.eta_seconds,
            do: gettext("done in %{eta}", eta: format_eta(@summary.eta_seconds)),
            else: gettext("no estimate")}
        </div>
      </div>
    </div>
    """
  end

  attr :tabs, :list, required: true, doc: "a list of `MydiaWeb.DownloadsLive.Tab` structs"
  attr :active, :atom, required: true
  slot :inner_block, required: true

  @doc """
  The page's tabs as `tabs-lift` patch links, with the page body in a
  `tab-content` panel right after the active link.

  daisyUI 5.7.44 treats `[aria-current=page]` as active and shows a
  `.tab-content` that directly follows an active tab, so no `tab-active`
  class is needed. Links, not `role="tab"`: they navigate, and a `tablist`
  would promise arrow-key handling this does not provide.
  """
  def tab_bar(assigns) do
    ~H"""
    <div id="downloads-tabs" class="tabs tabs-lift">
      <%= for %Tab{} = tab <- @tabs do %>
        <.link
          id={"downloads-tab-#{tab.key}"}
          patch={tab.href}
          class="tab gap-1.5"
          aria-current={tab.key == @active && "page"}
        >
          <.icon name={tab.icon} class="size-4" />
          {tab.label}
          <span
            :if={tab.count > 0}
            id={"downloads-tab-#{tab.key}-count"}
            class={["badge badge-sm tabular-nums", tab.tone == :error && "badge-error"]}
          >
            {tab.count}
          </span>
          <span
            :if={tab.dot?}
            id={"downloads-tab-#{tab.key}-stalled"}
            class="status status-warning"
            role="img"
            aria-label={gettext("Some downloads are stalled")}
          ></span>
        </.link>
        <div
          :if={tab.key == @active}
          id="downloads-tab-panel"
          class="tab-content bg-base-100 border-base-300 p-3 sm:p-4"
        >
          {render_slot(@inner_block)}
        </div>
      <% end %>
    </div>
    """
  end

  attr :id, :string, default: "downloads-empty-state"
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  slot :action

  @doc "The centred icon, title and hint shown when a tab or view has no rows."
  def empty_state(assigns) do
    ~H"""
    <div id={@id} class="flex flex-col items-center justify-center py-16 text-center">
      <.icon name={@icon} class="size-16 text-base-content/30 mb-4" />
      <h3 class="text-xl font-semibold text-base-content/70 mb-2">{@title}</h3>
      <p class="text-base-content/50">{@description}</p>
      <div :if={@action != []} class="mt-4">{render_slot(@action)}</div>
    </div>
    """
  end

  attr :filters, Filters, required: true
  attr :clients, :list, required: true
  attr :show_status?, :boolean, required: true

  slot :extra,
    doc: "Extra controls rendered last inside the form, so their inputs submit with the filter"

  def filter_bar(assigns) do
    assigns = assign(assigns, :status_options, ListView.status_options())

    ~H"""
    <form
      id="downloads-filter-form"
      phx-change="filter"
      phx-submit="filter"
      class="flex flex-wrap items-center gap-2"
    >
      <label class="input input-sm w-full sm:w-72">
        <.icon name="hero-magnifying-glass" class="size-4 opacity-50" />
        <input
          id="downloads-search"
          type="search"
          name="q"
          value={@filters.q}
          placeholder={gettext("Search downloads")}
          aria-label={gettext("Search downloads")}
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
        aria-label={gettext("Download client")}
      >
        <option value="">{gettext("All clients")}</option>
        <option :for={client <- @clients} value={client} selected={@filters.client == client}>
          {client}
        </option>
      </select>

      <div :if={@show_status?} id="downloads-status-filter" class="filter">
        <input
          class="btn btn-sm filter-reset"
          type="radio"
          name="status"
          value=""
          aria-label={gettext("All")}
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
      {render_slot(@extra)}
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
          aria-label={gettext("Remove filter %{filter}", filter: label)}
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
        {pgettext("filters", "Clear filters")}
      </button>
    </div>
    """
  end

  attr :client_urls, :map, required: true

  def client_shortcut(%{client_urls: urls} = assigns) when map_size(urls) == 1 do
    {name, url} = urls |> Map.to_list() |> hd()
    assigns = assign(assigns, name: name, url: url)

    ~H"""
    <a
      id="downloads-open-client"
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      class="btn btn-sm btn-ghost"
      title={gettext("Open %{name}", name: @name)}
      aria-label={gettext("Open %{name}", name: @name)}
    >
      <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
      <span class="hidden sm:inline ml-1">{gettext("Open %{name}", name: @name)}</span>
    </a>
    """
  end

  def client_shortcut(%{client_urls: urls} = assigns) when map_size(urls) > 1 do
    assigns = assign(assigns, :clients, Enum.sort_by(urls, fn {name, _url} -> name end))

    ~H"""
    <div class="dropdown dropdown-end z-20">
      <button
        id="downloads-open-client"
        type="button"
        tabindex="0"
        class="btn btn-sm btn-ghost"
        aria-label={gettext("Open download client")}
      >
        <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" />
        <span class="hidden sm:inline ml-1">{gettext("Open client")}</span>
      </button>
      <ul
        tabindex="0"
        class="dropdown-content menu bg-base-100 rounded-box shadow-lg border border-base-300 w-52 p-2"
      >
        <li :for={{name, url} <- @clients}>
          <a
            id={"downloads-open-client-#{ListView.slugify(name)}"}
            href={url}
            target="_blank"
            rel="noopener noreferrer"
            phx-click={JS.dispatch("mydia:blur")}
          >
            {name}
          </a>
        </li>
      </ul>
    </div>
    """
  end

  def client_shortcut(assigns), do: ~H""

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :url, :string, default: nil

  def client_chip(assigns) do
    ~H"""
    <%!-- A badge has a fixed height, so a long name is cut to one line. --%>
    <%= if @url do %>
      <span class="tooltip max-w-full min-w-0" data-tip={gettext("Open %{name}", name: @name)}>
        <a
          id={@id}
          href={@url}
          target="_blank"
          rel="noopener noreferrer"
          class="badge badge-ghost badge-sm gap-1 max-w-full hover:badge-outline transition-colors"
        >
          <.icon name="hero-server" class="size-3 shrink-0 opacity-70" />
          <span class="truncate min-w-0">{@name}</span>
          <.icon name="hero-arrow-top-right-on-square" class="size-3 shrink-0 opacity-70" />
        </a>
      </span>
    <% else %>
      <span id={@id} class="badge badge-ghost badge-sm gap-1 max-w-full" title={@name}>
        <.icon name="hero-server" class="size-3 shrink-0 opacity-70" />
        <span class="truncate min-w-0">{@name}</span>
      </span>
    <% end %>
    """
  end

  attr :download, :map, required: true
  attr :tab, :atom, required: true

  attr :context, :string,
    default: "row",
    doc: "\"row\" or \"drawer\"; prefixes ids and hides Details in the drawer"

  attr :class, :any, default: nil

  @doc """
  The action strip for one download: a `join` of icon buttons, with rarer
  actions in an "Actions" dropdown beside it (see
  lib/mydia_web/components/README.md on row actions and dropdown stacking).
  """
  def download_actions(assigns) do
    ~H"""
    <div
      :if={@tab in [:queue, :completed]}
      id={"#{@context}-actions-#{@download.id}"}
      class={["flex items-center gap-2 shrink-0", @class]}
    >
      <.row_actions id={"#{@context}-action-strip-#{@download.id}"}>
        <.row_action
          :if={@context == "row"}
          id={"download-details-#{@download.id}"}
          icon="hero-information-circle"
          title={gettext("Details")}
          phx-click="open_details"
          phx-value-id={@download.id}
        />
        <%= if @tab == :queue do %>
          <.row_action
            :if={@download.status == "paused"}
            id={"#{@context}-resume-#{@download.id}"}
            icon="hero-play"
            title={gettext("Resume download")}
            phx-click="resume_download"
            phx-value-id={@download.id}
          />
          <.row_action
            :if={@download.status != "paused"}
            id={"#{@context}-pause-#{@download.id}"}
            icon="hero-pause"
            title={gettext("Pause download")}
            phx-click="pause_download"
            phx-value-id={@download.id}
          />
          <%!-- Named: rows shift as others are removed, so the click can land on a neighbour. --%>
          <.row_action
            id={"#{@context}-cancel-#{@download.id}"}
            icon="hero-x-mark"
            title={gettext("Cancel download")}
            destructive
            phx-click="cancel_download"
            phx-value-id={@download.id}
            data-confirm={
              SeedingComponents.confirm_text(
                @download,
                gettext("Cancel %{title}?", title: ListView.display_title(@download))
              )
            }
          />
        <% else %>
          <.row_action
            :if={is_nil(@download.match_status) and @download.rematch_eligible?}
            id={"#{@context}-rematch-#{@download.id}"}
            icon="hero-arrow-path"
            title={gettext("Re-match to the correct title")}
            phx-click="open_match_modal"
            phx-value-id={@download.id}
            phx-value-mode="postimport"
          />
          <.row_action
            id={"#{@context}-clear-#{@download.id}"}
            icon="hero-trash"
            title={gettext("Clear completed download")}
            destructive
            phx-click="clear_single_completed"
            phx-value-id={@download.id}
            data-confirm={
              SeedingComponents.confirm_text(
                @download,
                gettext("Remove from client and clear from history?")
              )
            }
          />
        <% end %>
      </.row_actions>

      <div :if={@tab == :queue} class="dropdown dropdown-end z-20">
        <div
          tabindex="0"
          role="button"
          class="btn btn-sm btn-ghost btn-square"
          aria-label={gettext("More actions")}
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
              <.icon name="hero-pencil-square" class="size-4" /> {gettext("Change match")}
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
