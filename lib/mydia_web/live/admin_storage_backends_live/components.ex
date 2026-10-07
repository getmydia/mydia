defmodule MydiaWeb.AdminStorageBackendsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Settings.RuntimeConfig
  alias Mydia.Settings.StorageBackend

  attr :backends, :list, required: true
  attr :testing, :any, required: true

  def backends_list(assigns) do
    ~H"""
    <div id="storage-backends" class="card bg-base-100 shadow-sm">
      <div
        :if={@backends == []}
        id="storage-backends-empty"
        class="p-6 text-center text-base-content/60"
      >
        No storage backends yet. Add one to keep a library in an S3-compatible bucket.
      </div>
      <div class="divide-y divide-base-300">
        <div
          :for={backend <- @backends}
          id={"storage-backend-#{backend.name}"}
          class="flex flex-col sm:flex-row sm:items-center justify-between gap-3 p-4"
        >
          <div class="min-w-0">
            <div class="flex items-center gap-2">
              <span class="font-semibold">{backend.name}</span>
              <span
                :if={RuntimeConfig.runtime_config?(backend)}
                class="badge badge-primary badge-xs"
                title="Defined by environment or YAML"
              >
                env
              </span>
            </div>
            <div class="text-xs text-base-content/60 font-mono truncate">
              {endpoint_label(backend)} / {backend.bucket}
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button
              id={"test-storage-backend-#{backend.name}"}
              class="btn btn-ghost btn-sm"
              phx-click="test"
              phx-value-id={backend.id}
              disabled={MapSet.member?(@testing, backend.name)}
            >
              <span
                :if={MapSet.member?(@testing, backend.name)}
                class="loading loading-spinner loading-xs"
              />
              <.icon
                :if={not MapSet.member?(@testing, backend.name)}
                name="hero-signal"
                class="w-4 h-4"
              /> Test connection
            </button>
            <button
              :if={not RuntimeConfig.runtime_config?(backend)}
              id={"edit-storage-backend-#{backend.name}"}
              class="btn btn-ghost btn-sm"
              phx-click="edit"
              phx-value-id={backend.id}
            >
              <.icon name="hero-pencil-square" class="w-4 h-4" /> Edit
            </button>
            <button
              :if={not RuntimeConfig.runtime_config?(backend)}
              id={"delete-storage-backend-#{backend.name}"}
              class="btn btn-ghost btn-sm text-error"
              phx-click="delete"
              phx-value-id={backend.id}
              data-confirm={"Delete storage backend #{backend.name}?"}
            >
              <.icon name="hero-trash" class="w-4 h-4" /> Delete
            </button>
          </div>
        </div>
      </div>
    </div>
    <p id="storage-backends-help" class="text-sm text-base-content/60 mt-4">
      Use <code class="font-mono">s3://&lt;name&gt;/&lt;prefix&gt;</code> as a library path.
    </p>
    """
  end

  attr :form, :any, required: true
  attr :mode, :atom, required: true

  def backend_modal(assigns) do
    ~H"""
    <div class="modal modal-bottom sm:modal-middle modal-open" id="storage-backend-modal">
      <div class="modal-box max-w-xl">
        <h3 class="font-bold text-lg mb-4">
          {if @mode == :new, do: "Add storage backend", else: "Edit storage backend"}
        </h3>
        <.form
          for={@form}
          id="storage-backend-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-3"
        >
          <.input field={@form[:name]} type="text" label="Name" placeholder="media" required />
          <.input
            field={@form[:endpoint]}
            type="text"
            label="Endpoint"
            placeholder="https://minio.local:9000 (blank for AWS)"
          />
          <div class="grid grid-cols-2 gap-3">
            <.input field={@form[:region]} type="text" label="Region" required />
            <.input field={@form[:bucket]} type="text" label="Bucket" required />
          </div>
          <.input field={@form[:access_key_id]} type="text" label="Access key ID" required />
          <%!-- The stored secret is never sent back to the browser. --%>
          <.input
            field={@form[:secret_access_key]}
            type="password"
            label="Secret access key"
            value=""
            autocomplete="new-password"
            placeholder={if @mode == :edit, do: "Leave blank to keep"}
          />
          <.input field={@form[:path_style]} type="checkbox" label="Path-style addressing" />
          <div class="modal-action">
            <button type="button" class="btn btn-ghost" phx-click="close">Cancel</button>
            <button type="submit" class="btn btn-primary" phx-disable-with="Saving...">Save</button>
          </div>
        </.form>
      </div>
      <div class="modal-backdrop" phx-click="close"></div>
    </div>
    """
  end

  defp endpoint_label(%StorageBackend{endpoint: endpoint, region: region}) do
    if endpoint in [nil, ""], do: "AWS (#{region})", else: endpoint
  end
end
