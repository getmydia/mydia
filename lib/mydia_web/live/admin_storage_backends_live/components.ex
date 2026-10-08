defmodule MydiaWeb.AdminStorageBackendsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Settings.RuntimeConfig
  alias Mydia.Settings.StorageBackend

  @doc "The page header's Add button."
  def header_actions(assigns) do
    ~H"""
    <button id="new-storage-backend" class="btn btn-sm btn-primary" phx-click="new_storage_backend">
      <.icon name="hero-plus" class="w-4 h-4" /> Add storage backend
    </button>
    """
  end

  attr :backends, :list, required: true
  attr :testing, :any, required: true

  def storage_backends_tab(assigns) do
    ~H"""
    <div class="p-4 sm:p-6 space-y-4">
      <.admin_list id="storage-backends" items={@backends}>
        <:row :let={backend}>
          <.storage_backend_row backend={backend} testing?={MapSet.member?(@testing, backend.name)} />
        </:row>
        <:empty>
          No storage backends yet. Add one to keep a library in an S3-compatible bucket.
        </:empty>
      </.admin_list>
      <p id="storage-backends-help" class="text-sm text-base-content/60">
        Use <code class="font-mono">s3://&lt;name&gt;/&lt;prefix&gt;</code> as a library path.
      </p>
    </div>
    """
  end

  attr :backend, StorageBackend, required: true
  attr :testing?, :boolean, required: true

  defp storage_backend_row(assigns) do
    assigns = assign(assigns, :runtime?, RuntimeConfig.runtime_config?(assigns.backend))

    ~H"""
    <.admin_row id={"storage-backend-#{@backend.name}"}>
      <:title>
        {@backend.name}
        <.env_lock_badge :if={@runtime?} tip="Defined by environment or YAML (read-only)" />
      </:title>
      <:descriptor>
        <span class="font-mono">{endpoint_label(@backend)} / {@backend.bucket}</span>
      </:descriptor>
      <:actions>
        <.row_actions>
          <.row_action
            id={"test-storage-backend-#{@backend.name}"}
            icon="hero-signal"
            title="Test connection"
            loading={@testing?}
            phx-click="test_storage_backend"
            phx-value-id={@backend.id}
          />
          <.row_action
            id={"edit-storage-backend-#{@backend.name}"}
            icon="hero-pencil"
            title="Edit"
            disabled={@runtime?}
            disabled_reason={@runtime? && "Cannot edit a backend defined by environment or YAML"}
            phx-click="edit_storage_backend"
            phx-value-id={@backend.id}
          />
          <.row_action
            id={"delete-storage-backend-#{@backend.name}"}
            icon="hero-trash"
            title="Delete"
            destructive
            disabled={@runtime?}
            disabled_reason={@runtime? && "Cannot delete a backend defined by environment or YAML"}
            phx-click="delete_storage_backend"
            phx-value-id={@backend.id}
            data-confirm={"Delete storage backend #{@backend.name}?"}
          />
        </.row_actions>
      </:actions>
    </.admin_row>
    """
  end

  attr :storage_backend_form, :any, required: true
  attr :storage_backend_mode, :atom, required: true

  def storage_backend_modal(assigns) do
    ~H"""
    <.admin_modal
      id="storage-backend-modal"
      icon={if @storage_backend_mode == :new, do: "hero-plus-circle", else: "hero-pencil-square"}
      title={
        if @storage_backend_mode == :new, do: "Add storage backend", else: "Edit storage backend"
      }
      subtitle="An S3-compatible bucket a library can live in"
      on_close="close_storage_backend_modal"
    >
      <.form
        for={@storage_backend_form}
        id="storage-backend-form"
        phx-change="validate_storage_backend"
        phx-submit="save_storage_backend"
        class="space-y-3"
      >
        <.input
          field={@storage_backend_form[:name]}
          type="text"
          label="Name"
          placeholder="media"
          required
        />
        <.input
          field={@storage_backend_form[:endpoint]}
          type="text"
          label="Endpoint"
          placeholder="https://minio.local:9000 (blank for AWS)"
        />
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <.input field={@storage_backend_form[:region]} type="text" label="Region" required />
          <.input field={@storage_backend_form[:bucket]} type="text" label="Bucket" required />
        </div>
        <.input
          field={@storage_backend_form[:access_key_id]}
          type="text"
          label="Access key ID"
          required
        />
        <%!-- The stored secret is never sent back to the browser. --%>
        <.input
          field={@storage_backend_form[:secret_access_key]}
          type="password"
          label="Secret access key"
          value=""
          autocomplete="new-password"
          placeholder={if @storage_backend_mode == :edit, do: "Leave blank to keep"}
        />
        <.input
          field={@storage_backend_form[:path_style]}
          type="checkbox"
          label="Path-style addressing"
        />
        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" phx-click="close_storage_backend_modal">
            Cancel
          </button>
          <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">Save</button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  defp endpoint_label(%StorageBackend{endpoint: endpoint, region: region}) do
    if endpoint in [nil, ""], do: "AWS (#{region})", else: endpoint
  end
end
