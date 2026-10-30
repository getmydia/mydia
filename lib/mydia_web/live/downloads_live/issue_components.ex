defmodule MydiaWeb.DownloadsLive.IssueComponents do
  @moduledoc """
  The Issues tab: one row per `MydiaWeb.DownloadsLive.Issue`, the kind filter
  chips, and the alert for downloads whose client Mydia no longer tracks.
  """
  use MydiaWeb, :html

  import MydiaWeb.DownloadsLive.Format
  import MydiaWeb.Formatters

  alias MydiaWeb.DownloadsLive.{Issue, IssueList, ListComponents, ListView}
  alias MydiaWeb.Live.Components.LibrarySearchForm

  attr :counts, :map, required: true
  attr :selected, :atom, default: nil

  @doc """
  Radio chips, one per kind that has issues (or is the selected kind). Meant to
  sit inside `ListComponents.filter_bar/1`'s `:extra` slot so the choice
  submits with the rest of the filters as `kind`.
  """
  def kind_filter(assigns) do
    assigns = assign(assigns, :kinds, IssueList.kinds())

    ~H"""
    <div id="issues-kind-filter" class="filter flex-wrap">
      <input
        class="btn btn-sm filter-reset"
        type="radio"
        name="kind"
        value=""
        aria-label={gettext("All")}
        checked={is_nil(@selected)}
      />
      <%= for {kind, label} <- @kinds, Map.get(@counts, kind, 0) > 0 or @selected == kind do %>
        <input
          id={"issues-kind-#{kind}"}
          class="btn btn-sm"
          type="radio"
          name="kind"
          value={kind}
          aria-label={"#{label} #{Map.get(@counts, kind, 0)}"}
          checked={@selected == kind}
        />
      <% end %>
    </div>
    """
  end

  attr :issue, Issue, required: true
  attr :id, :string, required: true
  attr :selection_mode, :boolean, default: false
  attr :selected?, :boolean, default: false
  attr :client_url, :string, default: nil
  attr :search_open?, :boolean, default: false
  attr :library_search_value, :string, default: ""
  attr :library_search_results, :list, default: []

  def issue_row(assigns) do
    issue = assigns.issue

    assigns =
      assigns
      |> assign(:selectable?, Issue.selectable?(issue))
      |> assign(:download_backed?, not is_nil(issue.download))
      |> assign(:kind_label, IssueList.label(issue.kind))

    ~H"""
    <li
      id={@id}
      class="list-row items-center gap-3 py-2.5 hover:bg-base-300/40 transition-colors"
    >
      <%!-- Checkbox (only for rows with a download, shown in selection mode) --%>
      <div
        :if={@selectable?}
        class={[
          "transition-all",
          (@selection_mode && "w-auto opacity-100") || "w-0 opacity-0 overflow-hidden"
        ]}
      >
        <input
          type="checkbox"
          class="checkbox checkbox-primary checkbox-sm"
          checked={@selected?}
          phx-click="toggle_select"
          phx-value-id={@issue.id}
          disabled={not @selection_mode}
        />
      </div>
      <div class="list-col-grow min-w-0">
        <div class="flex items-center gap-2 min-w-0">
          <span
            class={["status status-md shrink-0", status_class(@issue.kind)]}
            title={@kind_label}
            aria-label={@kind_label}
          ></span>
          <.link
            :if={@issue.media_item_id}
            navigate={~p"/media/#{@issue.media_item_id}"}
            class="link link-hover font-medium text-sm truncate min-w-0 max-sm:min-h-6"
          >
            {@issue.title}
          </.link>
          <span
            :if={is_nil(@issue.media_item_id)}
            class="font-medium text-sm truncate min-w-0"
          >
            {@issue.title}
          </span>
        </div>
        <%= cond do %>
          <% @download_backed? -> %>
            <button
              id={"issue-open-#{@issue.id}"}
              type="button"
              phx-click="open_details"
              phx-value-id={@issue.id}
              class="block max-w-full truncate text-left text-xs text-base-content/40 hover:text-base-content/70 cursor-pointer transition-colors max-sm:min-h-6"
            >
              {@issue.subtitle || gettext("Details")}
            </button>
          <% @issue.subtitle -> %>
            <div class="truncate text-xs text-base-content/40">{@issue.subtitle}</div>
          <% true -> %>
        <% end %>
        <div class="flex flex-wrap items-center gap-x-3 gap-y-1 mt-1 text-xs min-w-0">
          <span
            class={[
              "truncate min-w-0 basis-full sm:basis-auto sm:flex-1",
              reason_class(@issue.kind)
            ]}
            title={@issue.reason}
          >
            {@issue.reason}
          </span>
          <%= if @issue.kind == :import_failed do %>
            <span
              :if={(@issue.download.import_retry_count || 0) > 0}
              class="shrink-0 text-base-content/60"
            >
              {gettext("Attempt #%{count}", count: @issue.download.import_retry_count)}
            </span>
            <span :if={@issue.download.import_next_retry_at} class="shrink-0 text-base-content/60">
              {gettext("Next retry: %{time}",
                time: format_next_retry(@issue.download.import_next_retry_at)
              )}
            </span>
          <% end %>
          <%= if @issue.torrent do %>
            <span :if={@issue.torrent.status} class="badge badge-xs badge-ghost">
              {ListView.torrent_status_label(@issue.torrent.status)}
            </span>
            <span
              :if={@issue.torrent.status in [:downloading, :seeding]}
              class="shrink-0 tabular-nums text-base-content/60"
            >
              {format_progress(@issue.torrent.progress)}%
            </span>
          <% end %>
          <ListComponents.client_chip
            :if={@issue.client}
            id={"issue-client-#{@issue.id}"}
            name={@issue.client}
            url={@client_url}
          />
        </div>
        <%= if @issue.kind == :needs_matching and @search_open? do %>
          <div :if={@issue.torrent.suggestions != []} class="mt-2">
            <span class="text-xs text-base-content/60 mb-1 block">
              {gettext("Suggestions:")}
            </span>
            <div class="flex flex-wrap gap-2">
              <button
                :for={suggestion <- @issue.torrent.suggestions}
                id={"adopt-#{@issue.torrent.id}-#{suggestion.media_item_id}"}
                type="button"
                class="btn btn-xs btn-outline btn-primary h-auto min-h-6 max-w-full whitespace-normal text-left"
                phx-click="adopt_suggestion"
                phx-value-torrent_id={@issue.torrent.id}
                phx-value-media_item_id={suggestion.media_item_id}
                title={suggestion.match_reason}
              >
                <span class="line-clamp-2 min-w-0 break-words">{suggestion.title}</span>
                <span class="badge badge-xs ml-1 shrink-0">
                  {round(suggestion.confidence * 100)}%
                </span>
              </button>
            </div>
          </div>
          <LibrarySearchForm.library_search_form
            search_value={@library_search_value}
            search_results={@library_search_results}
            on_search="library_search"
            on_select="adopt_library_match"
            download_id={@issue.torrent.id}
          />
        <% end %>
      </div>
      <div class="flex items-center gap-1 shrink-0 max-sm:row-start-2 max-sm:col-span-full max-sm:justify-end max-sm:-mt-2">
        <.primary_action issue={@issue} />
        <.issue_menu :if={@download_backed?} issue={@issue} />
      </div>
    </li>
    """
  end

  attr :issue, Issue, required: true

  defp primary_action(%{issue: %Issue{kind: :needs_matching}} = assigns) do
    ~H"""
    <button
      id={"issue-match-#{@issue.id}"}
      type="button"
      class="btn btn-sm btn-outline"
      phx-click="toggle_search"
      phx-value-id={@issue.id}
    >
      <.icon name="hero-magnifying-glass" class="size-4" />
      <span class="hidden sm:inline">{gettext("Match…")}</span>
    </button>
    """
  end

  defp primary_action(%{issue: %Issue{kind: :unresolved}} = assigns) do
    ~H"""
    <button
      id={"match-files-#{@issue.id}"}
      type="button"
      class="btn btn-sm btn-outline"
      phx-click="open_match_files"
      phx-value-id={@issue.id}
    >
      <.icon name="hero-document-magnifying-glass" class="size-4" />
      <span class="hidden sm:inline">{gettext("Match files…")}</span>
    </button>
    """
  end

  defp primary_action(
         %{issue: %Issue{kind: :import_failed, download: %{path_mapping_suggestion: %{}}}} =
           assigns
       ) do
    assigns = assign(assigns, :suggestion, assigns.issue.download.path_mapping_suggestion)

    ~H"""
    <button
      id={"apply-mapping-#{@issue.id}"}
      type="button"
      class="btn btn-sm btn-warning"
      phx-click="apply_mapping_and_retry"
      phx-value-remote_prefix={@suggestion.remote_prefix}
      phx-value-local_prefix={@suggestion.local_prefix}
      phx-disable-with={gettext("Applying…")}
      aria-label={
        gettext("Apply mapping %{remote} to %{local} and retry",
          remote: @suggestion.remote_prefix,
          local: @suggestion.local_prefix
        )
      }
    >
      {gettext("Apply mapping & retry")}
    </button>
    """
  end

  defp primary_action(%{issue: %Issue{kind: :import_failed}} = assigns) do
    ~H"""
    <button
      id={"retry-import-#{@issue.id}"}
      type="button"
      class="btn btn-sm btn-outline"
      phx-click="retry_import"
      phx-value-id={@issue.id}
    >
      <.icon name="hero-arrow-path" class="size-4" />
      <span class="hidden sm:inline">{gettext("Retry import")}</span>
    </button>
    """
  end

  defp primary_action(%{issue: %Issue{kind: :download_failed}} = assigns) do
    ~H"""
    <button
      id={"retry-download-#{@issue.id}"}
      type="button"
      class="btn btn-sm btn-outline"
      phx-click="retry_download"
      phx-value-id={@issue.id}
    >
      <.icon name="hero-arrow-path" class="size-4" />
      <span class="hidden sm:inline">{gettext("Retry")}</span>
    </button>
    """
  end

  defp primary_action(%{issue: %Issue{kind: :missing}} = assigns) do
    ~H"""
    <button
      id={"dismiss-#{@issue.id}"}
      type="button"
      class="btn btn-sm btn-ghost"
      phx-click="dismiss_download"
      phx-value-id={@issue.id}
      data-confirm={gettext("Dismiss this issue?")}
    >
      <.icon name="hero-x-mark" class="size-4" />
      <span class="hidden sm:inline">{gettext("Dismiss")}</span>
    </button>
    """
  end

  defp primary_action(%{issue: %Issue{kind: :removal_failed}} = assigns) do
    ~H"""
    <button
      id={"retry-removal-#{@issue.id}"}
      type="button"
      class="btn btn-sm btn-outline"
      phx-click="retry_removal"
      phx-value-id={@issue.id}
    >
      <.icon name="hero-arrow-path" class="size-4" />
      <span class="hidden sm:inline">{gettext("Retry removal")}</span>
    </button>
    """
  end

  attr :issue, Issue, required: true

  # Native popover plus CSS anchor positioning, same pattern as #downloads-more:
  # the menu renders in the top layer so list rows never clip it.
  defp issue_menu(assigns) do
    ~H"""
    <button
      id={"issue-menu-#{@issue.id}"}
      type="button"
      class="btn btn-sm btn-ghost btn-square"
      popovertarget={"issue-menu-list-#{@issue.id}"}
      style={"anchor-name:--issue-menu-#{@issue.id}"}
      aria-label={gettext("More actions")}
      title={gettext("More actions")}
    >
      <.icon name="hero-ellipsis-horizontal" class="size-4" />
    </button>
    <ul
      id={"issue-menu-list-#{@issue.id}"}
      popover
      class="dropdown dropdown-end menu w-48 rounded-box bg-base-100 border border-base-300 p-2 shadow-lg"
      style={"position-anchor:--issue-menu-#{@issue.id}"}
    >
      <li>
        <button
          id={"issue-menu-details-#{@issue.id}"}
          type="button"
          popovertarget={"issue-menu-list-#{@issue.id}"}
          popovertargetaction="hide"
          phx-click="open_details"
          phx-value-id={@issue.id}
        >
          <.icon name="hero-information-circle" class="size-4" /> {gettext("Details")}
        </button>
      </li>
      <%!-- A failed import's files can still be matched by hand. --%>
      <li :if={@issue.kind == :import_failed}>
        <button
          id={"issue-menu-match-files-#{@issue.id}"}
          type="button"
          popovertarget={"issue-menu-list-#{@issue.id}"}
          popovertargetaction="hide"
          phx-click="open_match_files"
          phx-value-id={@issue.id}
        >
          <.icon name="hero-document-magnifying-glass" class="size-4" /> {gettext("Match files…")}
        </button>
      </li>
      <li :if={@issue.kind != :missing}>
        <button
          id={"issue-menu-dismiss-#{@issue.id}"}
          type="button"
          popovertarget={"issue-menu-list-#{@issue.id}"}
          popovertargetaction="hide"
          phx-click="dismiss_download"
          phx-value-id={@issue.id}
          data-confirm={gettext("Dismiss this issue?")}
        >
          <.icon name="hero-x-mark" class="size-4" /> {gettext("Dismiss")}
        </button>
      </li>
    </ul>
    """
  end

  attr :group, :map, required: true

  def removed_client_alert(assigns) do
    ~H"""
    <div
      id={"removed-client-#{@group.slug}"}
      class="alert alert-warning flex flex-col items-start gap-2 sm:flex-row sm:items-center"
    >
      <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
      <div class="min-w-0 flex-1 break-words">
        <%!--
          Deliberately neutral about *why* the client is gone. The group
          covers both a deleted client and one that is merely disabled,
          and calling a disabled client "removed" steers the operator
          toward clearing records whose actual fix is to switch the
          client back on.
        --%>
        <div class="font-semibold">
          {ngettext(
            "%{count} download references '%{client}', which Mydia is no longer tracking",
            "%{count} downloads reference '%{client}', which Mydia is no longer tracking",
            @group.count,
            client: @group.download_client
          )}
        </div>
        <div class="text-sm opacity-80">
          {gettext(
            "Re-enabling or re-adding a client that holds these same torrents will restore them automatically."
          )}
        </div>
      </div>
      <button
        id={"clear-removed-client-#{@group.slug}"}
        type="button"
        class="btn btn-sm btn-warning"
        phx-click="clear_removed_client"
        phx-value-client={@group.download_client}
        data-confirm={
          ngettext(
            "Clear %{count} download from '%{client}'? This removes the record from Mydia only.",
            "Clear %{count} downloads from '%{client}'? This removes the records from Mydia only.",
            @group.count,
            client: @group.download_client
          )
        }
      >
        {gettext("Clear them")}
      </button>
    </div>
    """
  end

  defp status_class(kind) when kind in [:needs_matching, :unresolved], do: "status-warning"
  defp status_class(:missing), do: "status-neutral"
  defp status_class(_failed), do: "status-error"

  defp reason_class(kind) when kind in [:needs_matching, :unresolved], do: "text-warning"
  defp reason_class(:missing), do: "text-base-content/60"
  defp reason_class(_failed), do: "text-error"
end
