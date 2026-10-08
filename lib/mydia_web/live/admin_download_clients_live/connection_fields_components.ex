defmodule MydiaWeb.AdminDownloadClientsLive.ConnectionFieldsComponents do
  @moduledoc false
  use MydiaWeb, :html

  attr :download_client_form, :any, required: true

  def debrid_fields(assigns) do
    ~H"""
    <%!-- Debrid-specific fields --%>
    <div class="space-y-3">
      <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
        <.icon name="hero-cloud" class="w-4 h-4" />
        <span>Debrid Service</span>
      </div>

      <div class="alert alert-info text-sm py-2">
        <.icon name="hero-information-circle" class="w-4 h-4" />
        <span>
          Releases are submitted to your chosen provider and downloaded on their
          infrastructure. Your IP never participates in the swarm.
        </span>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <.input
          name="download_client_config[connection_settings][provider]"
          type="select"
          label="Provider"
          options={[
            {"Real-Debrid", "real_debrid"},
            {"AllDebrid", "all_debrid"},
            {"Premiumize", "premiumize"},
            {"TorBox", "tor_box"}
          ]}
          value={
            get_in(
              Phoenix.HTML.Form.input_value(@download_client_form, :connection_settings) ||
                %{},
              ["provider"]
            ) || "real_debrid"
          }
          required
        />
        <.input
          field={@download_client_form[:api_key]}
          type="password"
          label="API Key"
          required
        />
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <.input
          field={@download_client_form[:download_directory]}
          type="text"
          label="Download Directory (optional)"
          placeholder="/data/debrid-downloads"
        />
      </div>

      <p class="text-xs text-base-content/60">
        Where Mydia writes files pulled from the debrid provider before
        importing them into your library. Defaults to <code>/data/debrid-downloads</code>
        when the standard <code>/data</code>
        volume is mounted, otherwise the system temp directory.
        Override only if you need a specific filesystem (e.g., a faster
        disk or one with more headroom).
      </p>
    </div>
    """
  end

  attr :download_client_form, :any, required: true

  def blackhole_fields(assigns) do
    ~H"""
    <%!-- Blackhole-specific fields --%>
    <div class="space-y-3">
      <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
        <.icon name="hero-folder" class="w-4 h-4" />
        <span>Folder Settings</span>
      </div>

      <div class="alert alert-info text-sm py-2">
        <.icon name="hero-information-circle" class="w-4 h-4" />
        <span>
          Blackhole writes .torrent files to a watch folder for external processing.
        </span>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <.input
          name="download_client_config[connection_settings][watch_folder]"
          type="text"
          label="Watch Folder"
          placeholder="/path/to/watch"
          value={
            get_in(
              Phoenix.HTML.Form.input_value(@download_client_form, :connection_settings) ||
                %{},
              ["watch_folder"]
            ) || ""
          }
          required
        />
        <.input
          name="download_client_config[connection_settings][completed_folder]"
          type="text"
          label="Completed Folder"
          placeholder="/path/to/completed"
          value={
            get_in(
              Phoenix.HTML.Form.input_value(@download_client_form, :connection_settings) ||
                %{},
              ["completed_folder"]
            ) || ""
          }
          required
        />
      </div>

      <div class="flex items-center justify-between bg-base-200 rounded-lg px-4 py-3">
        <div class="flex items-center gap-3">
          <.icon name="hero-folder-open" class="w-4 h-4 text-base-content/60" />
          <div>
            <span class="text-sm font-medium">Category Subfolders</span>
            <p class="text-xs text-base-content/50">Create movies/tv subfolders</p>
          </div>
        </div>
        <input
          type="hidden"
          name="download_client_config[connection_settings][use_category_subfolders]"
          value="false"
        />
        <input
          type="checkbox"
          name="download_client_config[connection_settings][use_category_subfolders]"
          value="true"
          checked={
            get_in(
              Phoenix.HTML.Form.input_value(@download_client_form, :connection_settings) ||
                %{},
              ["use_category_subfolders"]
            ) in [true, "true"]
          }
          class="toggle toggle-primary toggle-sm"
        />
      </div>
    </div>
    """
  end

  attr :download_client_form, :any, required: true

  def network_fields(assigns) do
    ~H"""
    <%!-- Network client fields --%>
    <div class="space-y-3">
      <div class="flex items-center gap-2 text-sm font-medium text-base-content/80">
        <.icon name="hero-server" class="w-4 h-4" />
        <span>Connection</span>
      </div>

      <div class="grid grid-cols-6 gap-3">
        <div class="col-span-6 md:col-span-4">
          <.input
            field={@download_client_form[:host]}
            type="text"
            label="Host"
            placeholder="localhost"
            required
          />
        </div>
        <div class="col-span-3 md:col-span-1">
          <.input
            field={@download_client_form[:port]}
            type="number"
            label="Port"
            required
          />
        </div>
        <div class="col-span-3 md:col-span-1">
          <.input field={@download_client_form[:use_ssl]} type="checkbox" label="SSL" />
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <.input field={@download_client_form[:username]} type="text" label="Username" />
        <.input field={@download_client_form[:password]} type="password" label="Password" />
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <.input field={@download_client_form[:api_key]} type="password" label="API Key" />
        <.input
          field={@download_client_form[:url_base]}
          type="text"
          label="URL Base"
          placeholder="/transmission/"
        />
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <.input
          field={@download_client_form[:download_directory]}
          type="text"
          label="Download Directory"
        />
      </div>
    </div>
    """
  end
end
