defmodule MydiaWeb.ProfileLive.PasskeysComponent do
  @moduledoc """
  Profile card for adding, renaming and removing passkeys.

  A LiveComponent for the same reason as `TwoFactorComponent`: adding a
  passkey is a multi-step flow, and the WebAuthn challenge must stay in this
  process between sending the options and verifying the answer. The
  `PasskeyRegister` hook on the root element runs the browser side and
  reports whether this browser can use passkeys. `page_url` is the URL the
  profile page was loaded from; the passkey is bound to its host.
  """
  use MydiaWeb, :live_component

  alias Mydia.Accounts
  alias MydiaWeb.PasskeySession
  alias MydiaWeb.ProfileLive.SecondFactorThrottle

  @rate_limited "Too many login attempts. Please try again later."
  @bad_password "Current password is incorrect"
  @browser_errors %{
    "cancelled" => "The passkey request was cancelled or timed out.",
    "duplicate" => "This device already has a passkey for this account"
  }

  @impl true
  def update(%{user_id: user_id, page_url: page_url} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(:relying_party, PasskeySession.relying_party(page_url))
     |> assign_new(:supported?, fn -> false end)
     |> assign_new(:step, fn -> :idle end)
     |> assign_new(:error, fn -> nil end)
     |> assign_new(:challenge, fn -> nil end)
     |> assign_new(:target, fn -> nil end)
     |> assign_new(:form, fn -> password_form() end)
     |> load_passkeys(user_id)}
  end

  @impl true
  def handle_event("passkey_support", %{"supported" => supported}, socket),
    do: {:noreply, assign(socket, :supported?, supported == true)}

  def handle_event("start_add", _params, socket),
    do: {:noreply, assign(socket, step: :add, error: nil, form: password_form())}

  def handle_event("add", _params, %{assigns: %{relying_party: :unavailable}} = socket),
    do: {:noreply, reset_flow(socket)}

  def handle_event("add", %{"passkey" => %{"password" => password}}, socket) do
    %{user: user, relying_party: {:ok, rp}} = socket.assigns

    result =
      SecondFactorThrottle.run(user, fn ->
        Accounts.begin_passkey_registration(user, password, rp.rp_id, rp.origin)
      end)

    case result do
      {:ok, {challenge, options}} ->
        {:noreply,
         socket
         |> assign(step: :waiting, challenge: challenge, error: nil)
         |> push_event("passkey:register", %{options: options})}

      {:error, :invalid_password} ->
        {:noreply, assign(socket, error: @bad_password)}

      {:error, :rate_limited} ->
        {:noreply, assign(socket, error: @rate_limited)}
    end
  end

  def handle_event(
        "passkey_registered",
        %{"credential" => %{} = credential} = params,
        %{assigns: %{challenge: %Wax.Challenge{} = challenge, user: user}} = socket
      ) do
    case Accounts.register_passkey(user, challenge, credential, params["name"]) do
      {:ok, _passkey} ->
        {:noreply, socket |> reset_flow() |> load_passkeys(user.id)}

      {:error, :already_registered} ->
        {:noreply, retry(socket, @browser_errors["duplicate"])}

      {:error, _reason} ->
        {:noreply, retry(socket, "Passkey not recognised")}
    end
  end

  def handle_event("passkey_registered", _params, socket),
    do: {:noreply, retry(socket, "Sign-in expired, please try again")}

  def handle_event("passkey_failed", params, socket) do
    message = Map.get(@browser_errors, params["reason"], "Passkey not recognised")
    {:noreply, retry(socket, message)}
  end

  def handle_event("start_rename", %{"id" => id}, socket) do
    case find(socket, id) do
      nil ->
        {:noreply, socket}

      passkey ->
        {:noreply,
         assign(socket,
           step: :rename,
           target: passkey,
           error: nil,
           form: to_form(%{"name" => passkey.name}, as: :rename)
         )}
    end
  end

  def handle_event(
        "rename",
        %{"rename" => %{"name" => name}},
        %{assigns: %{target: %{} = target}} = socket
      ) do
    case Accounts.rename_passkey(socket.assigns.user, target.id, name) do
      {:ok, _} ->
        {:noreply, socket |> reset_flow() |> load_passkeys(socket.assigns.user.id)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, assign(socket, error: "Name must be 1 to 100 characters")}

      {:error, :not_found} ->
        {:noreply, socket |> reset_flow() |> load_passkeys(socket.assigns.user.id)}
    end
  end

  def handle_event("start_delete", %{"id" => id}, socket) do
    case find(socket, id) do
      nil ->
        {:noreply, socket}

      passkey ->
        {:noreply,
         assign(socket, step: :delete, target: passkey, error: nil, form: password_form())}
    end
  end

  def handle_event(
        "delete",
        %{"passkey" => %{"password" => password}},
        %{assigns: %{target: %{} = target}} = socket
      ) do
    user = socket.assigns.user

    case SecondFactorThrottle.run(user, fn ->
           Accounts.delete_passkey(user, target.id, password)
         end) do
      {:ok, _} -> {:noreply, socket |> reset_flow() |> load_passkeys(user.id)}
      {:error, :invalid_password} -> {:noreply, assign(socket, error: @bad_password)}
      {:error, :rate_limited} -> {:noreply, assign(socket, error: @rate_limited)}
      {:error, :not_found} -> {:noreply, socket |> reset_flow() |> load_passkeys(user.id)}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, reset_flow(socket)}

  defp retry(socket, message),
    do: assign(socket, step: :add, challenge: nil, error: message, form: password_form())

  defp reset_flow(socket),
    do:
      assign(socket, step: :idle, challenge: nil, target: nil, error: nil, form: password_form())

  defp load_passkeys(socket, user_id) do
    user = Accounts.get_user!(user_id)
    assign(socket, user: user, passkeys: Accounts.list_passkeys(user))
  end

  defp find(socket, id), do: Enum.find(socket.assigns.passkeys, &(&1.id == id))

  defp password_form, do: to_form(%{"password" => ""}, as: :passkey)

  defp available?(%{supported?: true, relying_party: {:ok, _}}), do: true
  defp available?(_assigns), do: false

  defp format_date(nil), do: "never"
  defp format_date(datetime), do: Calendar.strftime(datetime, "%b %d, %Y")

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :available?, available?(assigns))

    ~H"""
    <div
      id="passkeys"
      class="mt-6 border-t border-base-300 pt-6"
      phx-hook="PasskeyRegister"
      phx-target={@myself}
    >
      <h3 class="font-semibold flex items-center gap-2 mb-2">
        <.icon name="hero-finger-print" class="w-5 h-5" /> Passkeys
      </h3>

      <p :if={@passkeys == []} id="passkey-2fa-note" class="text-base-content/70 mb-4">
        Sign in with your fingerprint, face or device PIN instead of a password. Once you add a
        passkey, signing in with your password will also ask for it (or your authenticator code).
      </p>

      <ul :if={@passkeys != []} class="divide-y divide-base-300 mb-4">
        <li
          :for={passkey <- @passkeys}
          id={"passkey-#{passkey.id}"}
          class="flex flex-wrap items-center gap-3 py-2"
        >
          <div class="flex-1 min-w-0">
            <div class="font-medium truncate">{passkey.name}</div>
            <div class="text-xs text-base-content/60">
              Works at {passkey.rp_id} · Added {format_date(passkey.inserted_at)} · Last used {format_date(
                passkey.last_used_at
              )}
            </div>
          </div>
          <button
            type="button"
            id={"passkey-rename-#{passkey.id}"}
            class="btn btn-ghost btn-sm"
            phx-click="start_rename"
            phx-value-id={passkey.id}
            phx-target={@myself}
          >
            Rename
          </button>
          <button
            type="button"
            id={"passkey-delete-#{passkey.id}"}
            class="btn btn-ghost btn-sm text-error"
            phx-click="start_delete"
            phx-value-id={passkey.id}
            phx-target={@myself}
          >
            Remove
          </button>
        </li>
      </ul>

      <%= if @available? do %>
        <button
          type="button"
          id="add-passkey"
          class="btn btn-outline"
          phx-click="start_add"
          phx-target={@myself}
        >
          <.icon name="hero-plus" class="w-4 h-4" /> Add a passkey
        </button>
      <% else %>
        <p id="passkey-unsupported" class="text-sm text-base-content/60">
          Adding a passkey needs a browser that supports them and a secure (https) address for Mydia.
        </p>
      <% end %>

      <div :if={@step != :idle} class="modal modal-open" id="passkey-modal">
        <div class="modal-box">
          <h3 class="font-bold text-lg mb-4">
            <%= case @step do %>
              <% :rename -> %>
                Rename passkey
              <% :delete -> %>
                Remove passkey
              <% _ -> %>
                Add a passkey
            <% end %>
          </h3>

          <div :if={@error} class="alert alert-error mb-4" id="passkey-modal-error">
            <.icon name="hero-exclamation-circle" class="w-5 h-5" />
            <span>{@error}</span>
          </div>

          <%= case @step do %>
            <% :add -> %>
              <.form for={@form} id="passkey-password-form" phx-submit="add" phx-target={@myself}>
                <.input field={@form[:password]} type="password" label="Current password" required />
                <div class="modal-action">
                  <button type="button" class="btn btn-ghost" phx-click="close" phx-target={@myself}>Cancel</button>
                  <button type="submit" class="btn btn-primary">Continue</button>
                </div>
              </.form>
            <% :waiting -> %>
              <div class="flex items-center gap-3">
                <span class="loading loading-spinner loading-md"></span>
                <span>Follow your browser's prompt to create the passkey.</span>
              </div>
              <div class="modal-action">
                <button type="button" class="btn btn-ghost" phx-click="close" phx-target={@myself}>Cancel</button>
              </div>
            <% :rename -> %>
              <.form for={@form} id="passkey-rename-form" phx-submit="rename" phx-target={@myself}>
                <.input field={@form[:name]} type="text" label="Name" maxlength="100" required />
                <div class="modal-action">
                  <button type="button" class="btn btn-ghost" phx-click="close" phx-target={@myself}>Cancel</button>
                  <button type="submit" class="btn btn-primary">Save</button>
                </div>
              </.form>
            <% :delete -> %>
              <p class="mb-4">
                Remove <span class="font-medium">{@target.name}</span>? You won't be able to sign in with it again.
              </p>
              <.form for={@form} id="passkey-delete-form" phx-submit="delete" phx-target={@myself}>
                <.input field={@form[:password]} type="password" label="Current password" required />
                <div class="modal-action">
                  <button type="button" class="btn btn-ghost" phx-click="close" phx-target={@myself}>Cancel</button>
                  <button type="submit" class="btn btn-error">Remove</button>
                </div>
              </.form>
          <% end %>
        </div>
        <div class="modal-backdrop" phx-click="close" phx-target={@myself}></div>
      </div>
    </div>
    """
  end
end
