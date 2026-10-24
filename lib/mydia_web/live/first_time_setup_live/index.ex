defmodule MydiaWeb.FirstTimeSetupLive.Index do
  @moduledoc """
  First-time setup flow for creating the initial admin user.

  This LiveView is only accessible when no users exist in the system.
  It guides users through creating an admin account with either:
  - A custom password of their choice
  - A randomly generated secure password
  """
  use MydiaWeb, :live_view

  on_mount {MydiaWeb.Live.UserAuth, :put_locale}

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian

  @impl true
  def mount(_params, _session, socket) do
    # Redirect to home if users already exist
    if Accounts.any_users_exist?() do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Welcome to Mydia")
       |> assign(:password_mode, :custom)
       |> assign(:generated_password, nil)
       |> assign(:oidc_configured, oidc_configured?())
       |> assign(:local_auth_enabled, local_auth_enabled?())
       |> assign(:form, to_form(Accounts.change_user(%Accounts.User{})))}
    end
  end

  defp oidc_configured? do
    case Application.get_env(:ueberauth, Ueberauth) do
      nil -> false
      config -> Keyword.get(config, :providers, []) != []
    end
  end

  defp local_auth_enabled? do
    config = Mydia.Config.get()
    config.auth.local_enabled
  end

  @impl true
  def handle_event("change_password_mode", %{"mode" => mode}, socket) do
    password_mode = String.to_atom(mode)
    {:noreply, assign(socket, :password_mode, password_mode)}
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      %Accounts.User{}
      |> Accounts.change_user(user_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("create_admin", %{"user" => user_params}, socket) do
    # Generate random password if in random mode
    final_params =
      if socket.assigns.password_mode == :random do
        generated_password = generate_secure_password()
        Map.put(user_params, "password", generated_password)
      else
        user_params
      end

    # Always set role to admin for first user
    final_params = Map.put(final_params, "role", "admin")

    case Accounts.create_user(final_params) do
      {:ok, user} ->
        # Update last login timestamp
        Accounts.update_last_login(user)

        # Sign in the new admin user
        {:ok, token, _claims} = Guardian.create_token(user)

        # Attach hook to set session on next mount
        socket =
          attach_hook(socket, :set_session, :handle_params, fn _params, _url, socket ->
            {:cont,
             socket
             |> Phoenix.Component.assign_new(:session_updated, fn -> false end)}
          end)

        # If random password was generated, show it once
        if socket.assigns.password_mode == :random do
          generated_password = Map.get(final_params, "password")

          {:noreply,
           socket
           |> assign(:generated_password, generated_password)
           |> assign(:auth_token, token)
           |> assign(:user_id, user.id)
           |> put_flash(:info, "Admin user created successfully!")}
        else
          # Redirect to auto-login endpoint for custom password
          {:noreply,
           socket
           |> put_flash(:info, "Admin user created successfully! You are now logged in.")
           |> push_navigate(to: ~p"/auth/auto-login?token=#{token}")}
        end

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("continue_to_app", _params, socket) do
    # Redirect to auto-login endpoint with the token
    token = Map.get(socket.assigns, :auth_token)

    {:noreply,
     socket
     |> put_flash(:info, "Welcome to Mydia!")
     |> push_navigate(to: ~p"/auth/auto-login?token=#{token}")}
  end

  defp generate_secure_password do
    # Generate a cryptographically secure random password
    :crypto.strong_rand_bytes(24)
    |> Base.url_encode64()
    |> binary_part(0, 24)
  end
end
