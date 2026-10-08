defmodule MydiaWeb.AdminLibraryPathsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Settings.LibraryPath

  @doc """
  Renders the Library Paths tab content.
  """
  attr :library_paths, :list, required: true
  attr :reorganizing_library_ids, :any, default: MapSet.new()
  attr :reclassifying_library_ids, :any, default: MapSet.new()

  def library_paths_tab(assigns) do
    {enabled, disabled} = Enum.split_with(assigns.library_paths, &(!&1.disabled))

    assigns =
      assigns
      |> assign(:enabled_paths, enabled)
      |> assign(:disabled_paths, disabled)

    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <%= if @library_paths == [] do %>
        <div class="alert alert-info">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>No library paths configured yet. Add a media directory to get started.</span>
        </div>
      <% else %>
        <%!-- Enabled Libraries --%>
        <%= if @enabled_paths != [] do %>
          <div class="bg-base-200 rounded-box divide-y divide-base-300">
            <%= for library_path <- @enabled_paths do %>
              <.library_path_row
                library_path={library_path}
                is_reorganizing={MapSet.member?(@reorganizing_library_ids, library_path.id)}
                is_reclassifying={MapSet.member?(@reclassifying_library_ids, library_path.id)}
              />
            <% end %>
          </div>
        <% end %>

        <%!-- Disabled Libraries --%>
        <%= if @disabled_paths != [] do %>
          <div class="divider text-base-content/50 text-sm">
            <.icon name="hero-eye-slash" class="w-4 h-4" /> Disabled ({length(@disabled_paths)})
          </div>
          <div class="bg-base-200 rounded-box divide-y divide-base-300 opacity-60">
            <%= for library_path <- @disabled_paths do %>
              <.library_path_row
                library_path={library_path}
                is_reorganizing={MapSet.member?(@reorganizing_library_ids, library_path.id)}
                is_reclassifying={MapSet.member?(@reclassifying_library_ids, library_path.id)}
              />
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  @doc "The page header's Export menu and New button."
  def header_actions(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <div class="dropdown md:dropdown-end">
        <div tabindex="0" role="button" id="library-export-menu" class="btn btn-sm btn-ghost">
          <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Export
        </div>
        <ul tabindex="0" class="dropdown-content menu bg-base-200 rounded-box z-10 w-40 p-2 shadow">
          <li>
            <a id="library-export-json" href={~p"/api/v1/library/export?format=json"} download>
              JSON
            </a>
          </li>
          <li>
            <a id="library-export-csv" href={~p"/api/v1/library/export?format=csv"} download>
              CSV
            </a>
          </li>
        </ul>
      </div>
      <button class="btn btn-sm btn-primary" phx-click="new_library_path">
        <.icon name="hero-plus" class="w-4 h-4" /> New
      </button>
    </div>
    """
  end

  attr :library_path, :map, required: true
  attr :is_reorganizing, :boolean, default: false
  attr :is_reclassifying, :boolean, default: false

  defp library_path_row(assigns) do
    assigns =
      assign(
        assigns,
        :metadata_source,
        library_metadata_source(
          assigns.library_path.type,
          assigns.library_path.tv_metadata_source
        )
      )

    ~H"""
    <div id={"library-path-#{@library_path.id}"} class="p-3 sm:p-4">
      <div class="flex flex-col sm:flex-row sm:items-center gap-3">
        <%!-- Path Info --%>
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 flex-wrap">
            <span id={"library-path-#{@library_path.id}-name"} class="font-semibold">
              {LibraryPath.display_name(@library_path)}
            </span>
            <%= if @library_path.from_env do %>
              <span
                class="badge badge-primary badge-xs tooltip"
                data-tip="Configured via environment variables (read-only)"
              >
                <.icon name="hero-lock-closed" class="w-3 h-3" /> ENV
              </span>
            <% end %>
          </div>
          <div class="text-xs opacity-60 font-mono truncate mt-0.5">{@library_path.path}</div>
          <%= if @library_path.last_scan_at do %>
            <div class="text-xs opacity-50 mt-1">
              Last scan: {Calendar.strftime(@library_path.last_scan_at, "%Y-%m-%d %H:%M")}
            </div>
          <% end %>
        </div>

        <%!-- Badges + Actions --%>
        <div class="flex flex-wrap items-center gap-2">
          <%= if @metadata_source do %>
            <span
              class={["badge badge-sm tooltip", metadata_source_badge_class(@metadata_source)]}
              data-tip="Metadata source"
            >
              <.icon name="hero-circle-stack" class="w-3 h-3 mr-1" />
              {metadata_source_display(@metadata_source)}
            </span>
          <% end %>
          <span class={["badge badge-sm", library_type_badge_class(@library_path.type)]}>
            <.icon name={library_type_icon(@library_path.type)} class="w-3 h-3 mr-1" />
            {library_type_display(@library_path.type)}
          </span>
          <span
            :if={@library_path.default_for_movies or @library_path.default_for_series}
            class="badge badge-sm badge-outline"
          >
            Default
          </span>
          <span class={[
            "badge badge-sm",
            if(@library_path.monitored, do: "badge-success", else: "badge-ghost")
          ]}>
            {if @library_path.monitored, do: "Monitored", else: "Not Monitored"}
          </span>

          <div class="flex items-center gap-2 ml-auto sm:ml-2">
            <%!-- Organize dropdown - Re-classify always available, Reorganize only if auto_organize enabled --%>
            <%= cond do %>
              <% @is_reorganizing -> %>
                <div class="btn btn-sm btn-ghost gap-1 no-animation">
                  <span class="loading loading-spinner loading-xs"></span>
                  <span class="hidden sm:inline">Reorganizing...</span>
                </div>
              <% @is_reclassifying -> %>
                <div class="btn btn-sm btn-ghost gap-1 no-animation">
                  <span class="loading loading-spinner loading-xs"></span>
                  <span class="hidden sm:inline">Reclassifying...</span>
                </div>
              <% true -> %>
                <div class="dropdown dropdown-end">
                  <div tabindex="0" role="button" class="btn btn-sm btn-ghost gap-1">
                    <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
                    <span class="hidden sm:inline">Actions</span>
                    <.icon name="hero-chevron-down" class="w-3 h-3" />
                  </div>
                  <ul
                    tabindex="0"
                    class="dropdown-content z-[1] menu p-2 shadow-lg bg-base-100 rounded-box w-56"
                  >
                    <li>
                      <button phx-click="reclassify_library" phx-value-id={@library_path.id}>
                        <.icon name="hero-tag" class="w-4 h-4" /> Re-classify All
                      </button>
                    </li>
                    <%= if @library_path.auto_organize do %>
                      <li class="menu-title pt-2">
                        <span>File Organization</span>
                      </li>
                      <li>
                        <button phx-click="preview_reorganize" phx-value-id={@library_path.id}>
                          <.icon name="hero-eye" class="w-4 h-4" /> Preview Organization
                        </button>
                      </li>
                      <li>
                        <button phx-click="reorganize_library" phx-value-id={@library_path.id}>
                          <.icon name="hero-folder-arrow-down" class="w-4 h-4" /> Reorganize Files
                        </button>
                      </li>
                    <% else %>
                      <li class="menu-title pt-2">
                        <span class="text-base-content/50">File Organization</span>
                      </li>
                      <li class="disabled">
                        <span class="text-base-content/40 text-xs">
                          Enable auto-organize to move files
                        </span>
                      </li>
                    <% end %>
                  </ul>
                </div>
            <% end %>

            <div class="join">
              <%= if @library_path.from_env do %>
                <div class="tooltip" data-tip="Cannot edit environment-configured libraries">
                  <button class="btn btn-sm btn-ghost join-item" disabled>
                    <.icon name="hero-pencil" class="w-4 h-4 opacity-30" />
                  </button>
                </div>
                <div class="tooltip" data-tip="Cannot delete environment-configured libraries">
                  <button class="btn btn-sm btn-ghost join-item" disabled>
                    <.icon name="hero-trash" class="w-4 h-4 opacity-30" />
                  </button>
                </div>
              <% else %>
                <button
                  class="btn btn-sm btn-ghost join-item"
                  phx-click="edit_library_path"
                  phx-value-id={@library_path.id}
                  title="Edit"
                >
                  <.icon name="hero-pencil" class="w-4 h-4" />
                </button>
                <button
                  class="btn btn-sm btn-ghost join-item text-error"
                  phx-click="delete_library_path"
                  phx-value-id={@library_path.id}
                  data-confirm="Are you sure you want to delete this library path?"
                  title="Delete"
                >
                  <.icon name="hero-trash" class="w-4 h-4" />
                </button>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Library type helpers
  defp library_type_icon(:series), do: "hero-tv"
  defp library_type_icon(:movies), do: "hero-film"
  defp library_type_icon(:mixed), do: "hero-square-3-stack-3d"
  defp library_type_icon(_), do: "hero-folder"

  defp library_type_badge_class(:series), do: "badge-info"
  defp library_type_badge_class(:movies), do: "badge-accent"
  defp library_type_badge_class(:mixed), do: "badge-secondary"
  defp library_type_badge_class(_), do: "badge-ghost"

  defp library_type_display(:series), do: "Series"
  defp library_type_display(:movies), do: "Movies"
  defp library_type_display(:mixed), do: "Mixed"
  defp library_type_display(type), do: to_string(type)

  # Where a library's metadata comes from. Movies are always sourced from TMDB;
  # series/mixed use their configured TV provider (defaulting to TVDB for
  # runtime/env-only paths). Returns nil for types without a relay source so no
  # badge is rendered.
  defp library_metadata_source(:movies, _tv_source), do: :tmdb

  defp library_metadata_source(type, tv_source) when type in [:series, :mixed],
    do: tv_source || :tvdb

  defp library_metadata_source(_type, _tv_source), do: nil

  defp metadata_source_display(:tmdb), do: "TMDB"
  defp metadata_source_display(:tvdb), do: "TVDB"

  # Provider-distinct colors. `primary` and `neutral` are the only semantic
  # badge colors not used by the type badges (info/accent/secondary/success/
  # warning/error) or the green "Monitored" badge, so the source badge can never
  # match the type badge it sits next to.
  defp metadata_source_badge_class(:tmdb), do: "badge-primary"
  defp metadata_source_badge_class(:tvdb), do: "badge-neutral"
end
