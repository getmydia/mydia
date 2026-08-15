defmodule MydiaWeb.AdminLibraryPathsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

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
      <div class="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <h2 class="text-lg font-semibold flex items-center gap-2">
          <.icon name="hero-folder" class="w-5 h-5 opacity-60" /> Library Paths
          <span class="badge badge-ghost">{length(@library_paths)}</span>
        </h2>
        <button class="btn btn-sm btn-primary" phx-click="new_library_path">
          <.icon name="hero-plus" class="w-4 h-4" /> New
        </button>
      </div>

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

  @doc """
  Renders the Library Path modal.
  """
  attr :library_path_form, :any, required: true
  attr :library_path_mode, :atom, required: true

  def library_path_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-xl">
        <.form
          for={@library_path_form}
          id="library-path-form"
          phx-change="validate_library_path"
          phx-submit="save_library_path"
        >
          <%!-- Header --%>
          <div class="flex items-center justify-between mb-5">
            <div class="flex items-center gap-3">
              <div class="w-10 h-10 rounded-xl bg-primary/20 flex items-center justify-center">
                <.icon
                  name={
                    if(@library_path_mode == :new, do: "hero-folder-plus", else: "hero-pencil-square")
                  }
                  class="w-5 h-5 text-primary"
                />
              </div>
              <div>
                <h3 class="font-bold text-lg">
                  {if @library_path_mode == :new, do: "Add Library", else: "Edit Library"}
                </h3>
                <p class="text-sm text-base-content/60">
                  {if @library_path_mode == :new,
                    do: "Configure a new media directory",
                    else: "Update library settings"}
                </p>
              </div>
            </div>
            <label class="label cursor-pointer gap-2">
              <span class="label-text text-sm">Monitored</span>
              <input type="hidden" name={@library_path_form[:monitored].name} value="false" />
              <input
                type="checkbox"
                name={@library_path_form[:monitored].name}
                value="true"
                checked={
                  Phoenix.HTML.Form.normalize_value("checkbox", @library_path_form[:monitored].value)
                }
                class="toggle toggle-success toggle-sm"
              />
            </label>
          </div>
          <div class="space-y-5">
            <%!-- Path and Type Row --%>
            <div class="grid grid-cols-6 gap-3">
              <div class="col-span-6 md:col-span-4">
                <.input
                  field={@library_path_form[:path]}
                  type="text"
                  label="Path"
                  placeholder="/path/to/media"
                  required
                />
              </div>
              <div class="col-span-6 md:col-span-2">
                <.input
                  field={@library_path_form[:type]}
                  type="select"
                  label="Type"
                  options={[
                    {"Movies", "movies"},
                    {"TV Shows", "series"},
                    {"Mixed", "mixed"}
                  ]}
                  required
                />
              </div>
            </div>

            <%!-- Automatic scanning: opt-in per library. Presets rather than a
                  free-form seconds field, which is a demonstrated footgun here. --%>
            <div>
              <.input
                field={@library_path_form[:scan_interval]}
                type="select"
                label="Automatic scanning"
                options={[
                  {"Off (manual only)", nil},
                  {"Every 15 minutes", 900},
                  {"Every hour", 3600},
                  {"Every 6 hours", 21600},
                  {"Every 12 hours", 43200},
                  {"Daily", 86400}
                ]}
              />
              <p class="text-sm text-base-content/60 mt-1">
                How often Mydia rescans this folder for files added outside of downloads.
                Manual re-scans always work regardless of this setting.
              </p>
            </div>

            <%!-- TV Metadata Source (only for series/mixed) --%>
            <%= if to_string(@library_path_form[:type].value) in ["series", "mixed"] do %>
              <div class="grid grid-cols-6 gap-3">
                <div class="col-span-6 md:col-span-3">
                  <.input
                    field={@library_path_form[:tv_metadata_source]}
                    type="select"
                    label="TV Metadata Source"
                    options={[{"TheTVDB", "tvdb"}, {"TMDB", "tmdb"}]}
                  />
                  <p class="text-xs text-base-content/50 mt-1">
                    Provider for TV show metadata. Existing shows keep their data until refreshed.
                  </p>
                </div>
              </div>
            <% end %>

            <div class="divider my-1"></div>

            <%!-- Options Section --%>
            <div class="space-y-3">
              <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
                <.icon name="hero-cog-6-tooth" class="w-4 h-4" />
                <span>Options</span>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
                <%!-- Auto Import Toggle --%>
                <div class="flex items-center justify-between bg-base-200 rounded-lg px-4 py-3">
                  <div class="flex items-center gap-3">
                    <.icon name="hero-arrow-down-tray" class="w-4 h-4 text-base-content/60" />
                    <div>
                      <span class="text-sm font-medium">Auto Import</span>
                      <p class="text-xs text-base-content/50">Import new files automatically</p>
                    </div>
                  </div>
                  <input type="hidden" name={@library_path_form[:auto_import].name} value="false" />
                  <input
                    type="checkbox"
                    name={@library_path_form[:auto_import].name}
                    value="true"
                    checked={
                      Phoenix.HTML.Form.normalize_value(
                        "checkbox",
                        @library_path_form[:auto_import].value
                      )
                    }
                    class="toggle toggle-primary toggle-sm"
                  />
                </div>

                <%!-- Auto Organize Toggle --%>
                <div class="flex items-center justify-between bg-base-200 rounded-lg px-4 py-3">
                  <div class="flex items-center gap-3">
                    <.icon name="hero-folder-open" class="w-4 h-4 text-base-content/60" />
                    <div>
                      <span class="text-sm font-medium">Auto Organize</span>
                      <p class="text-xs text-base-content/50">Sort into category folders</p>
                    </div>
                  </div>
                  <input type="hidden" name={@library_path_form[:auto_organize].name} value="false" />
                  <input
                    type="checkbox"
                    name={@library_path_form[:auto_organize].name}
                    value="true"
                    checked={
                      Phoenix.HTML.Form.normalize_value(
                        "checkbox",
                        @library_path_form[:auto_organize].value
                      )
                    }
                    class="toggle toggle-secondary toggle-sm"
                  />
                </div>

                <.input
                  :if={@library_path_form[:type].value in ["movies", "mixed", :movies, :mixed]}
                  field={@library_path_form[:default_for_movies]}
                  type="checkbox"
                  label="Default library for movies"
                />
                <.input
                  :if={@library_path_form[:type].value in ["series", "mixed", :series, :mixed]}
                  field={@library_path_form[:default_for_series]}
                  type="checkbox"
                  label="Default library for series"
                />

                <%!-- Write NFO Toggle (only for movies/series/mixed) --%>
                <%= if to_string(@library_path_form[:type].value) in ["movies", "series", "mixed"] do %>
                  <div class="flex items-center justify-between bg-base-200 rounded-lg px-4 py-3">
                    <div class="flex items-center gap-3">
                      <.icon
                        name="hero-document-text"
                        class="w-4 h-4 text-base-content/60"
                      />
                      <div>
                        <span class="text-sm font-medium">Write NFO Files</span>
                        <p class="text-xs text-base-content/50">
                          Jellyfin/Kodi metadata files
                        </p>
                      </div>
                    </div>
                    <input type="hidden" name={@library_path_form[:write_nfo].name} value="false" />
                    <input
                      type="checkbox"
                      name={@library_path_form[:write_nfo].name}
                      value="true"
                      checked={
                        Phoenix.HTML.Form.normalize_value(
                          "checkbox",
                          @library_path_form[:write_nfo].value
                        )
                      }
                      class="toggle toggle-accent toggle-sm"
                    />
                  </div>
                <% end %>

                <%!-- Auto Rename Toggle --%>
                <div class="flex items-center justify-between bg-base-200 rounded-lg px-4 py-3">
                  <div class="flex items-center gap-3">
                    <.icon name="hero-pencil-square" class="w-4 h-4 text-base-content/60" />
                    <div>
                      <span class="text-sm font-medium">Auto Rename</span>
                      <p class="text-xs text-base-content/50">Rename files on import</p>
                    </div>
                  </div>
                  <input type="hidden" name={@library_path_form[:auto_rename].name} value="false" />
                  <input
                    type="checkbox"
                    name={@library_path_form[:auto_rename].name}
                    value="true"
                    checked={
                      Phoenix.HTML.Form.normalize_value(
                        "checkbox",
                        @library_path_form[:auto_rename].value
                      )
                    }
                    class="toggle toggle-warning toggle-sm"
                  />
                </div>
              </div>
            </div>

            <%!-- Category Paths (only shown when auto-organize is enabled) --%>
            <.auto_organize_paths form={@library_path_form} />
          </div>

          <div class="modal-action mt-6 pt-4 border-t border-base-300">
            <button type="button" class="btn btn-ghost" phx-click="close_library_path_modal">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary gap-2">
              <.icon name="hero-check" class="w-4 h-4" />
              {if @library_path_mode == :new, do: "Add Library", else: "Save Changes"}
            </button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop bg-black/50" phx-click="close_library_path_modal"></div>
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
            <span class="font-semibold">{Path.basename(@library_path.path)}</span>
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

  # Renders only the category paths section (when auto-organize is enabled).
  # Used by the compact library path modal.
  attr :form, :any, required: true

  defp auto_organize_paths(assigns) do
    library_type = get_library_type_from_form(assigns.form)
    categories = Mydia.Media.MediaCategory.for_library_type(library_type)

    assigns =
      assigns
      |> assign(:categories, categories)
      |> assign(:show_paths, auto_organize_enabled?(assigns.form) and categories != [])

    ~H"""
    <%= if @show_paths do %>
      <div class="space-y-3">
        <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
          <.icon name="hero-folder-open" class="w-4 h-4" />
          <span>Category Paths</span>
        </div>

        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <.category_path_input :for={category <- @categories} form={@form} category={category} />
        </div>

        <.category_path_preview form={@form} categories={@categories} />
      </div>
    <% end %>
    """
  end

  # Renders a single category path input field.
  attr :form, :any, required: true
  attr :category, :atom, required: true

  defp category_path_input(assigns) do
    category_key = Atom.to_string(assigns.category)
    category_paths = get_category_paths_from_form(assigns.form)
    current_value = Map.get(category_paths, category_key, "")

    assigns =
      assigns
      |> assign(:category_key, category_key)
      |> assign(:current_value, current_value)
      |> assign(:label, Mydia.Media.MediaCategory.label(assigns.category))

    ~H"""
    <div class="form-control">
      <label class="label py-1">
        <span class="label-text text-xs">{@label}</span>
      </label>
      <input
        type="text"
        name={"#{@form[:category_paths].name}[#{@category_key}]"}
        value={@current_value}
        placeholder="subfolder path"
        class="input input-bordered input-sm"
      />
    </div>
    """
  end

  # Renders a preview of the resolved category paths.
  attr :form, :any, required: true
  attr :categories, :list, required: true

  defp category_path_preview(assigns) do
    base_path = Phoenix.HTML.Form.input_value(assigns.form, :path) || ""
    category_paths = get_category_paths_from_form(assigns.form)

    resolved_paths =
      Enum.map(assigns.categories, fn category ->
        category_key = Atom.to_string(category)
        subpath = Map.get(category_paths, category_key, "")
        label = Mydia.Media.MediaCategory.label(category)

        resolved =
          if subpath == "" or subpath == nil do
            base_path
          else
            Path.join(base_path, subpath)
          end

        %{
          category: category,
          label: label,
          path: resolved,
          is_root: subpath == "" or subpath == nil
        }
      end)

    assigns =
      assigns
      |> assign(:base_path, base_path)
      |> assign(:resolved_paths, resolved_paths)

    ~H"""
    <div class="divider text-xs opacity-60">Path Preview</div>
    <div class="bg-base-300 rounded-lg p-3 font-mono text-xs space-y-1">
      <div class="text-base-content/60 mb-2">
        Base: <span class="text-primary">{@base_path || "(not set)"}</span>
      </div>
      <div :for={rp <- @resolved_paths} class="flex items-center gap-2">
        <span class={[
          "w-1.5 h-1.5 rounded-full shrink-0",
          if(rp.is_root, do: "bg-base-content/30", else: "bg-secondary")
        ]}></span>
        <span class="text-base-content/70">{rp.label}</span>
        <span class="text-base-content/40">→</span>
        <span class={if(rp.is_root, do: "text-base-content/50", else: "text-secondary")}>
          {rp.path || "(base)"}
        </span>
      </div>
    </div>
    """
  end

  # Helper to check if auto-organize is enabled
  defp auto_organize_enabled?(form) do
    Phoenix.HTML.Form.normalize_value(
      "checkbox",
      Phoenix.HTML.Form.input_value(form, :auto_organize)
    )
  end

  # Helper to get the library type from form
  defp get_library_type_from_form(form) do
    case Phoenix.HTML.Form.input_value(form, :type) do
      type when is_atom(type) -> type
      type when is_binary(type) -> String.to_existing_atom(type)
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # Helper to extract category_paths from form
  defp get_category_paths_from_form(form) do
    case Phoenix.HTML.Form.input_value(form, :category_paths) do
      paths when is_map(paths) -> paths
      _ -> %{}
    end
  end
end
