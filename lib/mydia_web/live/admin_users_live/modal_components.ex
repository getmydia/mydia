defmodule MydiaWeb.AdminUsersLive.ModalComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias Mydia.Accounts.User
  alias Mydia.Media.ContentRating
  alias Mydia.Media.MediaCategory

  defp roles do
    [
      {gettext("Guest"), "guest"},
      {gettext("Read Only"), "readonly"},
      {gettext("User"), "user"},
      {gettext("Admin"), "admin"}
    ]
  end

  attr :create_form, :any, required: true
  attr :generated_password, :string, default: nil
  attr :password_mode, :string, required: true
  attr :show_password, :boolean, required: true

  def create_user_modal(assigns) do
    ~H"""
    <.admin_modal
      id="create-user-modal"
      icon="hero-user-plus"
      title={gettext("Create Local User")}
      on_close="close_create_modal"
    >
      <%= if @generated_password do %>
        <.generated_password_notice
          heading={gettext("User created successfully!")}
          label={gettext("Generated Password")}
          password={@generated_password}
        />
        <.admin_modal_actions>
          <button type="button" phx-click="close_create_modal" class="btn btn-primary">
            {gettext("Done")}
          </button>
        </.admin_modal_actions>
      <% else %>
        <.form
          for={@create_form}
          id="create-user-form"
          phx-change="validate_create"
          phx-submit="submit_create"
        >
          <.input
            field={@create_form[:username]}
            type="text"
            label={gettext("Username")}
            placeholder="john_doe"
            required
          />
          <.input
            field={@create_form[:email]}
            type="email"
            label={gettext("Email")}
            placeholder="john@example.com"
            required
          />

          <div class="form-control mt-4">
            <label class="label"><span class="label-text">{gettext("Role")}</span></label>
            <select name="create[role]" class="select select-bordered">
              {Phoenix.HTML.Form.options_for_select(roles(), @create_form[:role].value || "guest")}
            </select>
          </div>

          <.password_mode_toggle
            id="create-password-mode"
            event="set_password_mode"
            mode={@password_mode}
          />

          <%= if @password_mode == "manual" do %>
            <.password_field
              field={@create_form[:password]}
              label={gettext("Password")}
              placeholder={gettext("Enter password (min 8 characters)")}
              show={@show_password}
              toggle="toggle_show_password"
            />
            <.password_field
              field={@create_form[:password_confirmation]}
              label={gettext("Confirm Password")}
              placeholder={gettext("Re-enter password")}
              show={@show_password}
              toggle="toggle_show_password"
            />
          <% else %>
            <div class="alert alert-info mt-4">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <span class="text-sm">
                {gettext("A random password will be generated and displayed after creation.")}
                {gettext("The user can change it after first login.")}
              </span>
            </div>
          <% end %>

          <.admin_modal_actions>
            <button type="button" phx-click="close_create_modal" class="btn btn-ghost">
              {gettext("Cancel")}
            </button>
            <button type="submit" class="btn btn-primary">{gettext("Create User")}</button>
          </.admin_modal_actions>
        </.form>
      <% end %>
    </.admin_modal>
    """
  end

  attr :user, :map, required: true
  attr :form, :any, required: true

  def edit_role_modal(assigns) do
    ~H"""
    <.admin_modal
      id="edit-role-modal"
      icon="hero-shield-check"
      title={gettext("Edit User Role")}
      subtitle={gettext("Change role for %{user}", user: User.label(@user))}
      on_close="close_edit_role_modal"
    >
      <.form
        for={@form}
        id="edit-role-form"
        phx-change="validate_edit_role"
        phx-submit="submit_edit_role"
      >
        <div class="form-control">
          <label class="label"><span class="label-text">{gettext("Role")}</span></label>
          <select name="edit_role[role]" class="select select-bordered">
            <option :for={{label, value} <- roles()} value={value} selected={@user.role == value}>
              {label}
            </option>
          </select>
        </div>

        <.admin_modal_actions>
          <button type="button" phx-click="close_edit_role_modal" class="btn btn-ghost">
            {gettext("Cancel")}
          </button>
          <button type="submit" class="btn btn-primary">{gettext("Update Role")}</button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  attr :user, :map, required: true
  attr :form, :any, required: true
  attr :generated_password, :string, default: nil
  attr :password_mode, :string, required: true
  attr :show_password, :boolean, required: true
  attr :success, :boolean, required: true

  def reset_password_modal(assigns) do
    ~H"""
    <.admin_modal
      id="reset-password-modal"
      icon="hero-key"
      title={gettext("Reset Password")}
      subtitle={gettext("Reset password for %{user}", user: User.label(@user))}
      on_close="close_reset_password_modal"
    >
      <%= if @success do %>
        <.generated_password_notice
          heading={gettext("Password reset successfully!")}
          label={gettext("New Password")}
          password={@generated_password}
        />
        <.admin_modal_actions>
          <button type="button" phx-click="close_reset_password_modal" class="btn btn-primary">
            {gettext("Done")}
          </button>
        </.admin_modal_actions>
      <% else %>
        <.password_mode_toggle
          id="reset-password-mode"
          event="set_reset_password_mode"
          mode={@password_mode}
        />

        <%= if @password_mode == "manual" do %>
          <.form
            for={@form}
            id="reset-password-form"
            phx-change="validate_reset_password"
            phx-submit="submit_reset_password"
          >
            <.password_field
              field={@form[:password]}
              label={gettext("New Password")}
              placeholder={gettext("Enter new password (min 8 characters)")}
              show={@show_password}
              toggle="toggle_show_password_reset"
            />
            <.password_field
              field={@form[:password_confirmation]}
              label={gettext("Confirm New Password")}
              placeholder={gettext("Re-enter new password")}
              show={@show_password}
              toggle="toggle_show_password_reset"
            />

            <div class="alert alert-warning mt-4">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span class="text-sm">
                {gettext("The old password will no longer work after reset.")}
              </span>
            </div>

            <.admin_modal_actions>
              <button type="button" phx-click="close_reset_password_modal" class="btn btn-ghost">
                {gettext("Cancel")}
              </button>
              <button type="submit" class="btn btn-warning">
                {gettext("Reset Password")}
              </button>
            </.admin_modal_actions>
          </.form>
        <% else %>
          <div class="alert alert-warning">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span class="text-sm">
              {gettext(
                "This will generate a new random password. The old password will no longer work."
              )}
            </span>
          </div>

          <.admin_modal_actions>
            <button type="button" phx-click="close_reset_password_modal" class="btn btn-ghost">
              {gettext("Cancel")}
            </button>
            <button type="button" phx-click="submit_reset_password" class="btn btn-warning">
              {gettext("Reset Password")}
            </button>
          </.admin_modal_actions>
        <% end %>
      <% end %>
    </.admin_modal>
    """
  end

  attr :user, :map, required: true

  def delete_user_modal(assigns) do
    ~H"""
    <.admin_modal
      id="delete-user-modal"
      icon="hero-trash"
      title={gettext("Delete User")}
      on_close="close_delete_modal"
    >
      <p class="text-sm text-base-content/70 mb-4" id="delete-modal-prompt">
        {gettext("Are you sure you want to delete %{user}?", user: User.label(@user))}
      </p>

      <div class="alert alert-error">
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <span class="text-sm">
          {gettext(
            "This action cannot be undone. All data associated with this user will be deleted."
          )}
        </span>
      </div>

      <.admin_modal_actions>
        <button type="button" phx-click="close_delete_modal" class="btn btn-ghost">
          {gettext("Cancel")}
        </button>
        <button type="button" phx-click="submit_delete" class="btn btn-error">
          {gettext("Delete User")}
        </button>
      </.admin_modal_actions>
    </.admin_modal>
    """
  end

  attr :user, :map, required: true
  attr :restriction, :map, default: nil
  attr :unrated_count, :integer, required: true

  def access_modal(assigns) do
    assigns =
      assigns
      |> assign(:categories, MediaCategory.all())
      |> assign(:thresholds, ContentRating.thresholds())
      |> assign(:selected, selected_categories(assigns.restriction))
      |> assign(:max_age, assigns.restriction && assigns.restriction.max_content_age)

    ~H"""
    <.admin_modal
      id="user-access-modal"
      icon="hero-lock-open"
      title={gettext("Library access for %{user}", user: @user.display_name || @user.username)}
      subtitle={
        gettext(
          "Restrict what this account can see, request, and play. Leaving both settings untouched gives full access."
        )
      }
      on_close="close_access_modal"
    >
      <.form for={%{}} as={:access} id="access-form" phx-submit="submit_access">
        <fieldset>
          <legend class="label-text font-semibold">{gettext("Categories")}</legend>
          <p class="text-sm opacity-70 mb-2">{gettext("Tick nothing to allow every category.")}</p>
          <div class="filter">
            <input
              :for={category <- @categories}
              type="checkbox"
              class="btn"
              name="access[allowed_categories][]"
              value={category}
              checked={to_string(category) in @selected}
              aria-label={category_label(category)}
            />
          </div>
        </fieldset>

        <fieldset class="mt-6">
          <legend class="label-text font-semibold">{gettext("Maximum age rating")}</legend>
          <.input
            type="select"
            id="access-max-age"
            name="access[max_content_age]"
            value={@max_age}
            prompt={gettext("No limit")}
            options={@thresholds}
            container_class="mt-2"
          />
          <p class="text-sm opacity-70 mt-2" id="unrated-count">
            {gettext(
              "Setting any limit also hides titles with no rating. %{count} of your library items currently have none.",
              count: @unrated_count
            )}
          </p>
        </fieldset>

        <.admin_modal_actions>
          <button type="button" class="btn btn-ghost" id="clear-access" phx-click="clear_access">
            {gettext("Remove all restrictions")}
          </button>
          <button type="button" class="btn" phx-click="close_access_modal">
            {gettext("Cancel")}
          </button>
          <button type="submit" class="btn btn-primary">{gettext("Save")}</button>
        </.admin_modal_actions>
      </.form>
    </.admin_modal>
    """
  end

  attr :heading, :string, required: true
  attr :label, :string, required: true
  attr :password, :string, default: nil

  defp generated_password_notice(assigns) do
    ~H"""
    <div class="alert alert-success mb-4">
      <.icon name="hero-check-circle" class="w-5 h-5" />
      <div class="flex-1">
        <div class="font-semibold">{@heading}</div>
        <div class="text-sm mt-1">
          {if @password,
            do: gettext("Save the password below - it won't be shown again."),
            else: gettext("The password has been updated.")}
        </div>
      </div>
    </div>

    <div :if={@password} class="form-control">
      <label class="label"><span class="label-text font-semibold">{@label}</span></label>
      <div class="bg-base-200 p-4 rounded-lg border-2 border-success">
        <code class="text-lg font-mono select-all">{@password}</code>
      </div>
      <label class="label"><span class="label-text-alt">{gettext("Click to select and copy")}</span></label>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :mode, :string, required: true

  defp password_mode_toggle(assigns) do
    ~H"""
    <div class="form-control mt-6 mb-4">
      <label class="label"><span class="label-text font-semibold">{gettext("Password Setup")}</span></label>
      <.segmented_control
        id={@id}
        value={@mode}
        event={@event}
        param="mode"
        label={gettext("Password setup")}
        size="md"
      >
        <:option value="auto" label={gettext("Auto-Generate")} icon="hero-sparkles" />
        <:option value="manual" label={gettext("Set Manually")} icon="hero-key" />
      </.segmented_control>
    </div>
    """
  end

  attr :field, :any, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, required: true
  attr :show, :boolean, required: true
  attr :toggle, :string, required: true

  defp password_field(assigns) do
    ~H"""
    <div class="form-control mt-4">
      <label class="label"><span class="label-text">{@label}</span></label>
      <div class="relative">
        <input
          type={if(@show, do: "text", else: "password")}
          name={@field.name}
          value={@field.value}
          class={["input input-bordered w-full pr-10", @field.errors != [] && "input-error"]}
          placeholder={@placeholder}
          required
        />
        <button
          type="button"
          phx-click={@toggle}
          class="absolute right-2 top-1/2 -translate-y-1/2 btn btn-ghost btn-sm btn-circle"
        >
          <.icon name={if(@show, do: "hero-eye-slash", else: "hero-eye")} class="w-5 h-5" />
        </button>
      </div>
      <label :if={@field.errors != []} class="label">
        <span class="label-text-alt text-error">
          {Enum.map_join(@field.errors, ", ", &translate_error/1)}
        </span>
      </label>
    </div>
    """
  end

  defp selected_categories(nil), do: []
  defp selected_categories(%{allowed_categories: nil}), do: []
  defp selected_categories(%{allowed_categories: categories}), do: categories

  defp category_label(:movie), do: gettext("Movies")
  defp category_label(:tv_show), do: gettext("TV shows")
  defp category_label(:anime_movie), do: gettext("Anime films")
  defp category_label(:anime_series), do: gettext("Anime series")
  defp category_label(:cartoon_movie), do: gettext("Cartoon films")
  defp category_label(:cartoon_series), do: gettext("Cartoon series")
end
