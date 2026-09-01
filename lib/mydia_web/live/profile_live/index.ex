defmodule MydiaWeb.ProfileLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Accounts
  alias Mydia.Accounts.UserPreference

  @themes [
    {"System", "system"},
    {"Light", "light"},
    {"Dark", "dark"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    is_oidc_user = Accounts.oidc_user?(user)
    preference = Accounts.get_user_preference!(user)

    socket =
      socket
      |> assign(:is_oidc_user, is_oidc_user)
      |> assign(:profile_form, to_form(Accounts.change_profile(user)))
      |> assign(:password_form, to_form(password_changeset(), as: :password))
      |> assign(:show_password_modal, false)
      |> assign(:password_error, nil)
      # Preferences
      |> assign(:preference, preference)
      |> assign(:themes, @themes)
      |> assign(:theme, UserPreference.theme(preference))

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, assign(socket, :page_title, "Profile & Preferences")}
  end

  ## Profile Events

  @impl true
  def handle_event("validate_profile", %{"user" => params}, socket) do
    changeset =
      socket.assigns.current_user
      |> Accounts.change_profile(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :profile_form, to_form(changeset))}
  end

  @impl true
  def handle_event("save_profile", %{"user" => params}, socket) do
    case Accounts.update_profile(socket.assigns.current_user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(:current_user, user)
         |> assign(:profile_form, to_form(Accounts.change_profile(user)))
         |> put_flash(:info, "Profile updated successfully")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("show_password_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_password_modal, true)
     |> assign(:password_form, to_form(password_changeset(), as: :password))
     |> assign(:password_error, nil)}
  end

  @impl true
  def handle_event("hide_password_modal", _params, socket) do
    {:noreply, assign(socket, :show_password_modal, false)}
  end

  @impl true
  def handle_event("validate_password", %{"password" => params}, socket) do
    changeset =
      password_changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :password_form, to_form(changeset, as: :password))}
  end

  @impl true
  def handle_event("change_password", %{"password" => params}, socket) do
    current_password = params["current_password"] || ""
    new_password = params["new_password"] || ""
    confirm_password = params["confirm_password"] || ""

    case Accounts.change_password(
           socket.assigns.current_user,
           current_password,
           new_password,
           confirm_password
         ) do
      {:ok, _user} ->
        {:noreply,
         socket
         |> assign(:show_password_modal, false)
         |> assign(:password_form, to_form(password_changeset(), as: :password))
         |> assign(:password_error, nil)
         |> put_flash(:info, "Password changed successfully")}

      {:error, :invalid_password} ->
        {:noreply, assign(socket, :password_error, "Current password is incorrect")}

      {:error, changeset} ->
        {:noreply, assign(socket, :password_form, to_form(changeset, as: :password))}
    end
  end

  ## Preferences Events

  @impl true
  def handle_event("update_theme", %{"theme" => theme}, socket) do
    case Accounts.update_preference(socket.assigns.preference, %{"theme" => theme}) do
      {:ok, preference} ->
        {:noreply,
         socket
         |> assign(:preference, preference)
         |> assign(:theme, theme)
         |> push_event("theme_changed", %{theme: theme})
         |> put_flash(:info, "Theme updated")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update theme")}
    end
  end

  @impl true
  def handle_event("toggle_hide_player", _params, socket) do
    hidden = !socket.assigns.hide_player

    case Accounts.update_preference(socket.assigns.preference, %{"hide_player" => hidden}) do
      {:ok, preference} ->
        {:noreply,
         socket
         |> assign(:preference, preference)
         |> assign(:hide_player, hidden)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update the player setting")}
    end
  end

  ## Private Helpers

  defp password_changeset(params \\ %{}) do
    types = %{
      current_password: :string,
      new_password: :string,
      confirm_password: :string
    }

    {%{}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
    |> Ecto.Changeset.validate_required([:current_password, :new_password, :confirm_password])
    |> Ecto.Changeset.validate_length(:new_password,
      min: 8,
      message: "must be at least 8 characters"
    )
    |> validate_password_confirmation()
  end

  defp validate_password_confirmation(changeset) do
    new_password = Ecto.Changeset.get_change(changeset, :new_password)
    confirm_password = Ecto.Changeset.get_change(changeset, :confirm_password)

    if new_password && confirm_password && new_password != confirm_password do
      Ecto.Changeset.add_error(changeset, :confirm_password, "does not match new password")
    else
      changeset
    end
  end

  defp auth_type(user) do
    if Accounts.oidc_user?(user) do
      "OpenID Connect (SSO)"
    else
      "Local"
    end
  end

  defp format_datetime(nil), do: "Never"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%b %d, %Y at %I:%M %p")
  end
end
