defmodule MydiaWeb.AdminLibraryPathsLive.LibraryPathModalComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Settings.LibraryPath

  @doc """
  Renders the Library Path modal.
  """
  attr :library_path_form, :any, required: true
  attr :library_path_mode, :atom, required: true

  def library_path_modal(assigns) do
    ~H"""
    <.admin_modal
      id="library-path-modal"
      icon={if @library_path_mode == :new, do: "hero-folder-plus", else: "hero-pencil-square"}
      title={if @library_path_mode == :new, do: "Add Library", else: "Edit Library"}
      subtitle={
        if @library_path_mode == :new,
          do: "Configure a new media directory",
          else: "Update library settings"
      }
      on_close="close_library_path_modal"
    >
      <:header_aside>
        <label class="label cursor-pointer gap-2">
          <span class="label-text text-sm">Monitored</span>
          <input
            type="hidden"
            form="library-path-form"
            name={@library_path_form[:monitored].name}
            value="false"
          />
          <input
            type="checkbox"
            form="library-path-form"
            name={@library_path_form[:monitored].name}
            value="true"
            checked={
              Phoenix.HTML.Form.normalize_value("checkbox", @library_path_form[:monitored].value)
            }
            class="toggle toggle-success toggle-sm"
          />
        </label>
      </:header_aside>
      <.form
        for={@library_path_form}
        id="library-path-form"
        phx-change="validate_library_path"
        phx-submit="save_library_path"
      >
        <div class="space-y-5">
          <div>
            <.input
              field={@library_path_form[:name]}
              type="text"
              label="Name"
              placeholder={name_placeholder(@library_path_form[:path].value)}
              maxlength="60"
            />
          </div>
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
              <p class="text-xs text-base-content/50 mt-1">
                A folder on this server, or s3://&lt;storage backend&gt;/&lt;prefix&gt;.
              </p>
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
                    <p class="text-xs text-base-content/50">
                      Let background scans import confident matches
                    </p>
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

        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_library_path_modal">
            Cancel
          </button>
          <button type="submit" class="btn btn-primary gap-2">
            <.icon name="hero-check" class="w-4 h-4" />
            {if @library_path_mode == :new, do: "Add Library", else: "Save Changes"}
          </button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

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

  defp name_placeholder(path) when is_binary(path) and path != "",
    do: LibraryPath.display_name(%{path: path})

  defp name_placeholder(_path), do: "Defaults to the folder name"
end
