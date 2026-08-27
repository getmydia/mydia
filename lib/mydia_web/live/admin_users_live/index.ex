defmodule MydiaWeb.AdminUsersLive.Index do
  use MydiaWeb, :live_view

  alias Mydia.Accounts
  alias Mydia.Accounts.Scope
  alias Mydia.Accounts.User
  alias Mydia.Media

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Manage Users")
     |> assign(:search_query, "")
     |> assign(:filter_role, "all")
     |> assign(:show_create_modal, false)
     |> assign(:show_edit_role_modal, false)
     |> assign(:show_reset_password_modal, false)
     |> assign(:show_delete_modal, false)
     |> assign(:show_access_modal, false)
     |> assign(:access_user, nil)
     |> assign(:access_restriction, nil)
     |> assign(:unrated_count, 0)
     |> assign(:selected_user, nil)
     |> assign(:generated_password, nil)
     |> assign(:password_mode, "auto")
     |> assign(:password_mode_reset, "auto")
     |> assign(:show_password, false)
     |> assign(:show_password_reset, false)
     |> assign(:password_reset_success, false)
     |> load_users()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_filters(socket, params)}
  end

  ## Event Handlers

  @impl true
  def handle_event("search", %{"search" => query}, socket) do
    {:noreply,
     socket
     |> assign(:search_query, query)
     |> load_users()}
  end

  def handle_event("filter", %{"role" => role}, socket) do
    {:noreply, push_patch(socket, to: ~p"/admin/users?role=#{role}")}
  end

  def handle_event("open_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_modal, true)
     |> assign(:generated_password, nil)
     |> assign(:password_mode, "auto")
     |> assign(:show_password, false)
     |> assign_create_form()}
  end

  def handle_event("close_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create_modal, false)
     |> assign(:generated_password, nil)
     |> assign(:password_mode, "auto")
     |> assign(:show_password, false)}
  end

  def handle_event("toggle_password_mode", %{"mode" => mode}, socket) do
    {:noreply,
     socket
     |> assign(:password_mode, mode)
     |> assign(:show_password, false)
     |> assign_create_form()}
  end

  def handle_event("toggle_show_password", _params, socket) do
    {:noreply, assign(socket, :show_password, !socket.assigns.show_password)}
  end

  def handle_event("validate_create", %{"create" => create_params}, socket) do
    changeset = validate_create(create_params, socket.assigns.password_mode)
    {:noreply, assign(socket, :create_form, to_form(changeset, as: :create))}
  end

  def handle_event("submit_create", %{"create" => create_params}, socket) do
    # First validate the form params through changeset
    changeset = validate_create(create_params, socket.assigns.password_mode)

    if changeset.valid? do
      # Extract validated data from changeset
      validated_data = Ecto.Changeset.apply_changes(changeset)

      # Determine password based on mode
      {password, attrs} =
        case socket.assigns.password_mode do
          "manual" ->
            # Use manually entered password from validated data
            attrs = %{
              username: validated_data.username,
              email: validated_data.email,
              password: validated_data.password,
              password_confirmation: validated_data.password_confirmation,
              role: validated_data.role || "guest"
            }

            {nil, attrs}

          "auto" ->
            # Generate a random password
            password = generate_password()

            attrs = %{
              username: validated_data.username,
              email: validated_data.email,
              password: password,
              role: validated_data.role || "guest"
            }

            {password, attrs}
        end

      case Accounts.create_user(attrs) do
        {:ok, _user} ->
          {:noreply,
           socket
           |> assign(:generated_password, password)
           |> put_flash(
             :info,
             if(password,
               do: "User created! Save the password shown below.",
               else: "User created successfully."
             )
           )
           |> load_users()}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to create user")
           |> assign(:create_form, to_form(changeset, as: :create))}
      end
    else
      # Validation failed - show errors
      {:noreply,
       socket
       |> put_flash(:error, "Please fix the errors below")
       |> assign(:create_form, to_form(changeset, as: :create))}
    end
  end

  def handle_event("open_edit_role_modal", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    {:noreply,
     socket
     |> assign(:show_edit_role_modal, true)
     |> assign(:selected_user, user)
     |> assign_edit_role_form(user)}
  end

  def handle_event("close_edit_role_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_edit_role_modal, false)
     |> assign(:selected_user, nil)}
  end

  def handle_event("validate_edit_role", %{"edit_role" => role_params}, socket) do
    changeset = validate_edit_role(role_params)
    {:noreply, assign(socket, :edit_role_form, to_form(changeset, as: :edit_role))}
  end

  def handle_event("submit_edit_role", %{"edit_role" => role_params}, socket) do
    user = socket.assigns.selected_user
    changeset = validate_edit_role(role_params)

    if changeset.valid? do
      validated_data = Ecto.Changeset.apply_changes(changeset)

      case Accounts.update_user_role(user, %{role: validated_data.role}) do
        {:ok, _updated_user} ->
          {:noreply,
           socket
           |> assign(:show_edit_role_modal, false)
           |> assign(:selected_user, nil)
           |> put_flash(:info, "User role updated successfully.")
           |> load_users()}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to update user role")
           |> assign(:edit_role_form, to_form(changeset, as: :edit_role))}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Please fix the errors below")
       |> assign(:edit_role_form, to_form(changeset, as: :edit_role))}
    end
  end

  def handle_event("open_reset_password_modal", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    if is_oidc_user?(user) do
      {:noreply,
       socket
       |> put_flash(:error, "Cannot reset password for OIDC users")}
    else
      {:noreply,
       socket
       |> assign(:show_reset_password_modal, true)
       |> assign(:selected_user, user)
       |> assign(:generated_password, nil)
       |> assign(:password_mode_reset, "auto")
       |> assign(:show_password_reset, false)
       |> assign(:password_reset_success, false)
       |> assign_reset_password_form()}
    end
  end

  def handle_event("close_reset_password_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reset_password_modal, false)
     |> assign(:selected_user, nil)
     |> assign(:generated_password, nil)
     |> assign(:password_mode_reset, "auto")
     |> assign(:show_password_reset, false)
     |> assign(:password_reset_success, false)}
  end

  def handle_event("toggle_password_mode_reset", %{"mode" => mode}, socket) do
    {:noreply,
     socket
     |> assign(:password_mode_reset, mode)
     |> assign(:show_password_reset, false)
     |> assign_reset_password_form()}
  end

  def handle_event("toggle_show_password_reset", _params, socket) do
    {:noreply, assign(socket, :show_password_reset, !socket.assigns.show_password_reset)}
  end

  def handle_event("validate_reset_password", %{"reset_password" => reset_params}, socket) do
    changeset = validate_reset_password(reset_params)
    {:noreply, assign(socket, :reset_password_form, to_form(changeset, as: :reset_password))}
  end

  def handle_event("submit_reset_password", params, socket) do
    user = socket.assigns.selected_user

    # Determine password based on mode
    {password, password_value, changeset} =
      case socket.assigns.password_mode_reset do
        "manual" ->
          reset_params = params["reset_password"] || %{}
          changeset = validate_reset_password(reset_params)

          if changeset.valid? do
            validated_data = Ecto.Changeset.apply_changes(changeset)
            {nil, validated_data.password, changeset}
          else
            {nil, nil, changeset}
          end

        "auto" ->
          password = generate_password()
          # Create a valid changeset for auto mode (no validation needed)
          changeset = validate_reset_password(%{})
          {password, password, changeset}
      end

    if changeset.valid? do
      case Accounts.update_password(user, password_value) do
        {:ok, _updated_user} ->
          {:noreply,
           socket
           |> assign(:generated_password, password)
           |> assign(:password_reset_success, true)
           |> put_flash(
             :info,
             if(password,
               do: "Password reset! Save the password shown below.",
               else: "Password reset successfully."
             )
           )}

        {:error, changeset} ->
          {:noreply,
           socket
           |> put_flash(:error, "Failed to reset password")
           |> assign(:reset_password_form, to_form(changeset, as: :reset_password))}
      end
    else
      {:noreply,
       socket
       |> put_flash(:error, "Please fix the errors below")
       |> assign(:reset_password_form, to_form(changeset, as: :reset_password))}
    end
  end

  def handle_event("open_delete_modal", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    # Prevent deleting current user
    if user.id == socket.assigns.current_user.id do
      {:noreply,
       socket
       |> put_flash(:error, "You cannot delete your own account")}
    else
      {:noreply,
       socket
       |> assign(:show_delete_modal, true)
       |> assign(:selected_user, user)}
    end
  end

  def handle_event("close_delete_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_modal, false)
     |> assign(:selected_user, nil)}
  end

  def handle_event("submit_delete", _params, socket) do
    user = socket.assigns.selected_user

    case Accounts.delete_user(user) do
      {:ok, _deleted_user} ->
        {:noreply,
         socket
         |> assign(:show_delete_modal, false)
         |> assign(:selected_user, nil)
         |> put_flash(:info, "User deleted successfully.")
         |> load_users()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete user")}
    end
  end

  def handle_event("open_access_modal", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    {:noreply,
     socket
     |> assign(:show_access_modal, true)
     |> assign(:access_user, user)
     |> assign(:access_restriction, Accounts.get_access_restriction(user))
     |> assign(:unrated_count, Media.count_unrated_items(Scope.system()))}
  end

  def handle_event("close_access_modal", _params, socket) do
    {:noreply, assign(socket, :show_access_modal, false)}
  end

  def handle_event("submit_access", %{"access" => params}, socket) do
    attrs = %{
      allowed_categories: Map.get(params, "allowed_categories", []),
      max_content_age: parse_age(Map.get(params, "max_content_age"))
    }

    case Accounts.upsert_access_restriction(socket.assigns.access_user, attrs) do
      {:ok, _restriction} ->
        {:noreply,
         socket
         |> assign(:show_access_modal, false)
         |> put_flash(:info, "Access updated")
         |> load_users()}

      {:error, :admin} ->
        {:noreply, put_flash(socket, :error, "Admins always have full access")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, error_message(changeset))}
    end
  end

  def handle_event("clear_access", _params, socket) do
    :ok = Accounts.clear_access_restriction(socket.assigns.access_user)

    {:noreply,
     socket
     |> assign(:show_access_modal, false)
     |> put_flash(:info, "Restrictions removed")}
  end

  ## Private Helpers

  defp apply_filters(socket, params) do
    role = params["role"] || "all"

    socket
    |> assign(:filter_role, role)
    |> load_users()
  end

  # An empty select value means "no limit", which is not the same as 0.
  # `Integer.parse/1` is used instead of `String.to_integer/1` because the
  # value arrives from a form post a caller fully controls; a crafted,
  # non-numeric `access[max_content_age]` must not crash the LiveView.
  defp parse_age(nil), do: nil
  defp parse_age(""), do: nil

  defp parse_age(value) when is_binary(value) do
    case Integer.parse(value) do
      {age, ""} -> age
      _ -> nil
    end
  end

  defp error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field}: #{Enum.join(messages, ", ")}" end)
  end

  defp load_users(socket) do
    # Build query with role filter
    opts =
      case socket.assigns.filter_role do
        "all" -> []
        role -> [role: role]
      end

    # Get users with preloaded associations for stats
    users =
      Accounts.list_users(Keyword.put(opts, :preload, [:media_requests, :approved_requests]))

    # Filter by search query if present
    users =
      if socket.assigns.search_query != "" do
        query = String.downcase(socket.assigns.search_query)

        Enum.filter(users, fn user ->
          String.contains?(String.downcase(user.username || ""), query) ||
            String.contains?(String.downcase(user.email || ""), query) ||
            String.contains?(String.downcase(user.display_name || ""), query)
        end)
      else
        users
      end

    # Add statistics
    users_with_stats =
      Enum.map(users, fn user ->
        %{
          user: user,
          requests_submitted: length(user.media_requests),
          requests_approved: Enum.count(user.approved_requests, &(&1.status == "approved")),
          requests_rejected: Enum.count(user.approved_requests, &(&1.status == "rejected"))
        }
      end)

    assign(socket, :users, users_with_stats)
  end

  defp assign_create_form(socket) do
    types =
      case socket.assigns.password_mode do
        "manual" ->
          %{
            username: :string,
            email: :string,
            role: :string,
            password: :string,
            password_confirmation: :string
          }

        "auto" ->
          %{
            username: :string,
            email: :string,
            role: :string
          }
      end

    data =
      case socket.assigns.password_mode do
        "manual" ->
          %{
            username: "",
            email: "",
            role: "guest",
            password: "",
            password_confirmation: ""
          }

        "auto" ->
          %{
            username: "",
            email: "",
            role: "guest"
          }
      end

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(data, Map.keys(types))
      |> Ecto.Changeset.validate_required([:username, :email])

    assign(socket, :create_form, to_form(changeset, as: :create))
  end

  defp assign_reset_password_form(socket) do
    types =
      case socket.assigns.password_mode_reset do
        "manual" ->
          %{
            password: :string,
            password_confirmation: :string
          }

        "auto" ->
          %{}
      end

    data =
      case socket.assigns.password_mode_reset do
        "manual" ->
          %{
            password: "",
            password_confirmation: ""
          }

        "auto" ->
          %{}
      end

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(data, Map.keys(types))

    assign(socket, :reset_password_form, to_form(changeset, as: :reset_password))
  end

  defp assign_edit_role_form(socket, user) do
    changeset =
      {%{},
       %{
         role: :string
       }}
      |> Ecto.Changeset.cast(
        %{
          role: user.role
        },
        [:role]
      )
      |> Ecto.Changeset.validate_required([:role])

    assign(socket, :edit_role_form, to_form(changeset, as: :edit_role))
  end

  defp validate_create(params, password_mode) do
    types =
      case password_mode do
        "manual" ->
          %{
            username: :string,
            email: :string,
            role: :string,
            password: :string,
            password_confirmation: :string
          }

        "auto" ->
          %{
            username: :string,
            email: :string,
            role: :string
          }
      end

    required_fields =
      case password_mode do
        "manual" -> [:username, :email, :password, :password_confirmation]
        "auto" -> [:username, :email]
      end

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(params, Map.keys(types))
      |> Ecto.Changeset.validate_required(required_fields)
      |> Ecto.Changeset.validate_format(:email, ~r/^[^\s]+@[^\s]+$/)

    # Add password validation if in manual mode
    changeset =
      if password_mode == "manual" do
        changeset
        |> Ecto.Changeset.validate_length(:password,
          min: 8,
          message: "must be at least 8 characters"
        )
        |> Ecto.Changeset.validate_confirmation(:password, message: "does not match password")
      else
        changeset
      end

    changeset
  end

  defp validate_reset_password(params) do
    types = %{
      password: :string,
      password_confirmation: :string
    }

    {%{}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
    |> Ecto.Changeset.validate_required([:password, :password_confirmation])
    |> Ecto.Changeset.validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> Ecto.Changeset.validate_confirmation(:password, message: "does not match password")
  end

  defp validate_edit_role(params) do
    types = %{
      role: :string
    }

    {%{}, types}
    |> Ecto.Changeset.cast(params, Map.keys(types))
    |> Ecto.Changeset.validate_required([:role])
    |> Ecto.Changeset.validate_inclusion(:role, User.valid_roles())
  end

  defp generate_password do
    # Generate a secure random password (16 characters)
    :crypto.strong_rand_bytes(12)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  defp is_oidc_user?(%User{oidc_sub: oidc_sub}) when not is_nil(oidc_sub), do: true
  defp is_oidc_user?(_user), do: false

  defp format_date(nil), do: "Never"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %Y")
  end

  defp role_badge_class("admin"), do: "badge-error"
  defp role_badge_class("user"), do: "badge-primary"
  defp role_badge_class("readonly"), do: "badge-info"
  defp role_badge_class("guest"), do: "badge-warning"
  defp role_badge_class(_), do: "badge-ghost"

  defp auth_type_text(%User{oidc_sub: oidc_sub}) when not is_nil(oidc_sub), do: "OIDC"
  defp auth_type_text(_user), do: "Local"
end
