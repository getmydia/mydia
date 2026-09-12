defmodule MydiaWeb.AdminApiKeysLive.Index do
  @moduledoc """
  The admin page for Library API keys.

  Lists the signed-in admin's own keys, creates Library API keys, and revokes or
  deletes them. A new key's plain value exists only while it is being created
  (`Mydia.Accounts.create_api_key/2` stores a hash), so the page shows it once,
  in a modal, and never again.

  A plain list rather than a stream, like the other `/admin/config` pages: an
  admin's keys are a handful, and the confirm flow looks keys up in it.
  """
  use MydiaWeb, :live_view

  alias Mydia.Accounts
  alias MydiaWeb.AdminApiKeysLive.Components

  @expiry_days %{"30" => 30, "90" => 90, "365" => 365}
  @form_types %{name: :string, expiry: :string, scope: :string}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - API Keys")
     |> assign(:active_tab, :api_keys)
     |> assign(:env_key_set, is_binary(Application.get_env(:mydia, :library_api_key)))
     |> assign(:show_api_key_modal, false)
     |> assign(:created_key, nil)
     |> assign(:confirm, nil)
     |> assign(:api_key_form, new_form())
     |> load_keys()}
  end

  @impl true
  def handle_event("new_api_key", _params, socket) do
    {:noreply, socket |> assign(:api_key_form, new_form()) |> assign(:show_api_key_modal, true)}
  end

  def handle_event("close_api_key_modal", _params, socket) do
    {:noreply, assign(socket, :show_api_key_modal, false)}
  end

  def handle_event("validate_api_key", %{"api_key" => params}, socket) do
    form = params |> changeset() |> Map.put(:action, :validate) |> to_form(as: :api_key)
    {:noreply, assign(socket, :api_key_form, form)}
  end

  def handle_event("save_api_key", %{"api_key" => params}, socket) do
    case params |> changeset() |> Ecto.Changeset.apply_action(:insert) do
      {:ok, attrs} ->
        create(socket, attrs)

      {:error, changeset} ->
        {:noreply, assign(socket, :api_key_form, to_form(changeset, as: :api_key))}
    end
  end

  def handle_event("close_created_api_key", _params, socket) do
    {:noreply, assign(socket, :created_key, nil)}
  end

  def handle_event("copy_api_key", _params, socket) do
    {:noreply, put_flash(socket, :info, "Key copied to clipboard")}
  end

  def handle_event("confirm_revoke_api_key", %{"id" => id}, socket),
    do: confirm(socket, :revoke, id)

  def handle_event("confirm_delete_api_key", %{"id" => id}, socket),
    do: confirm(socket, :delete, id)

  def handle_event("cancel_api_key_confirm", _params, socket) do
    {:noreply, assign(socket, :confirm, nil)}
  end

  def handle_event("revoke_api_key", _params, %{assigns: %{confirm: {:revoke, key}}} = socket) do
    socket |> assign(:confirm, nil) |> finish(Accounts.revoke_api_key(key), "Key revoked")
  end

  def handle_event("delete_api_key", _params, %{assigns: %{confirm: {:delete, key}}} = socket) do
    socket |> assign(:confirm, nil) |> finish(Accounts.delete_api_key(key), "Key deleted")
  end

  # A second click after the modal closed has nothing to act on.
  def handle_event(event, _params, socket) when event in ["revoke_api_key", "delete_api_key"] do
    {:noreply, socket}
  end

  # Only a key already in this admin's own list can be acted on. The Accounts
  # functions check no ownership, so this lookup is what stops one admin from
  # revoking another's key by posting its id.
  defp confirm(socket, action, id) do
    case Enum.find(socket.assigns.api_keys, &(&1.id == id)) do
      nil -> {:noreply, put_flash(socket, :error, "That key no longer exists")}
      key -> {:noreply, assign(socket, :confirm, {action, key})}
    end
  end

  defp finish(socket, {:ok, _key}, message) do
    {:noreply, socket |> put_flash(:info, message) |> load_keys()}
  end

  defp finish(socket, {:error, _reason}, _message) do
    {:noreply, socket |> put_flash(:error, "Could not update the key") |> load_keys()}
  end

  # v1 offers one scope, the Library API, stored as the admin permission the
  # Library API's authentication plug requires.
  defp create(socket, attrs) do
    params = %{name: attrs.name, permissions: ["admin"], expires_at: expires_at(attrs.expiry)}

    case Accounts.create_api_key(socket.assigns.current_user.id, params) do
      {:ok, _key, plain_key} ->
        {:noreply,
         socket
         |> assign(:show_api_key_modal, false)
         |> assign(:created_key, plain_key)
         |> load_keys()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create the key")}
    end
  end

  defp expires_at("never"), do: nil

  defp expires_at(days) do
    DateTime.utc_now()
    |> DateTime.add(Map.fetch!(@expiry_days, days) * 86_400, :second)
    |> DateTime.truncate(:second)
  end

  # Schemaless: ApiKey's own changeset requires the key and its hash, which do
  # not exist until create_api_key/2 generates them.
  defp changeset(params) do
    {%{}, @form_types}
    |> Ecto.Changeset.cast(params, Map.keys(@form_types))
    |> Ecto.Changeset.validate_required([:name, :expiry, :scope])
    |> Ecto.Changeset.validate_length(:name, min: 1, max: 100)
    |> Ecto.Changeset.validate_inclusion(:expiry, ["never" | Map.keys(@expiry_days)])
    |> Ecto.Changeset.validate_inclusion(:scope, ["library"])
  end

  defp new_form do
    %{"name" => "", "expiry" => "never", "scope" => "library"}
    |> changeset()
    |> to_form(as: :api_key)
  end

  defp load_keys(socket) do
    assign(socket, :api_keys, Accounts.list_api_keys(socket.assigns.current_user.id))
  end
end
