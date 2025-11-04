defmodule MydiaWeb.Live.UserAuth do
  @moduledoc """
  LiveView authentication hooks.

  Provides `on_mount` hooks for LiveViews to authenticate users
  and assign current_user to the socket.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian

  @doc """
  LiveView mount hook for authentication and authorization.

  Supports multiple modes:
  - `:ensure_authenticated` - Requires user to be logged in
  - `:maybe_authenticated` - Loads user if present, but doesn't require it
  - `{:ensure_role, role}` - Requires user to have a specific role

  Usage in LiveView:
      on_mount {MydiaWeb.Live.UserAuth, :ensure_authenticated}
      on_mount {MydiaWeb.Live.UserAuth, :maybe_authenticated}
      on_mount {MydiaWeb.Live.UserAuth, {:ensure_role, :admin}}
  """
  def on_mount(mode, params, session, socket)

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns[:current_user] do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You must be logged in to access this page")
        |> redirect(to: "/auth/login")

      {:halt, socket}
    end
  end

  def on_mount(:maybe_authenticated, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount({:ensure_role, required_role}, _params, session, socket) do
    socket = mount_current_user(socket, session)

    if socket.assigns[:current_user] && has_role?(socket.assigns.current_user, required_role) do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, "You do not have permission to access this page")
        |> redirect(to: "/")

      {:halt, socket}
    end
  end

  # Mount the current user from the session
  defp mount_current_user(socket, session) do
    case session do
      %{"guardian_token" => token} ->
        case Guardian.verify_token(token) do
          {:ok, user} ->
            assign(socket, current_user: user)

          {:error, _reason} ->
            assign(socket, current_user: nil)
        end

      %{"user_id" => user_id} ->
        # Fallback: load user by ID if no Guardian token
        case Accounts.get_user!(user_id) do
          user -> assign(socket, current_user: user)
        end

      _ ->
        assign(socket, current_user: nil)
    end
  rescue
    Ecto.NoResultsError ->
      assign(socket, current_user: nil)
  end

  # Check if user has the required role
  defp has_role?(user, required_role) do
    role_hierarchy = %{
      "admin" => 3,
      "user" => 2,
      "readonly" => 1
    }

    user_level = Map.get(role_hierarchy, user.role, 0)
    required_level = Map.get(role_hierarchy, to_string(required_role), 999)

    user_level >= required_level
  end
end
