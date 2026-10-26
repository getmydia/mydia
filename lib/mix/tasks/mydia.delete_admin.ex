defmodule Mix.Tasks.Mydia.DeleteAdmin do
  @moduledoc """
  Deletes admin users from the system.

  This task finds all users with admin role and removes them from the database.
  Works with both local auth users and OIDC users.

  ## Examples

      mix mydia.delete_admin              # Delete all admin users
      mix mydia.delete_admin --email=user@example.com  # Delete specific admin by email

  """
  use Mix.Task

  @shortdoc "Deletes admin users from the system"

  @impl Mix.Task
  def run(args) do
    # Start the application to load configuration
    Mix.Task.run("app.start")

    alias Mydia.Accounts

    # Parse options
    {opts, _} = OptionParser.parse!(args, strict: [email: :string])

    admin_users =
      case opts[:email] do
        nil ->
          # Delete all admin users
          Accounts.list_users(role: "admin")

        email ->
          # Delete specific admin by email
          case Accounts.get_user_by_email(email) do
            nil ->
              []

            user ->
              if user.role == "admin" do
                [user]
              else
                Mix.shell().error("✗ User #{email} is not an admin (role: #{user.role})")
                exit({:shutdown, 1})
              end
          end
      end

    case admin_users do
      [] ->
        Mix.shell().info("ℹ No admin users found. Nothing to delete.")
        :ok

      users ->
        Mix.shell().info("Found #{length(users)} admin user(s):")

        Enum.each(users, fn user ->
          display_name = user.email || user.username || "ID: #{user.id}"
          Mix.shell().info("  - #{display_name} (#{Accounts.auth_method_label(user)})")
        end)

        # Delete all admin users
        results =
          Enum.map(users, fn user ->
            display_name = user.email || user.username || "ID: #{user.id}"

            case Accounts.delete_user(user) do
              {:ok, _user} ->
                Mix.shell().info("✓ Deleted admin user: #{display_name}")
                :ok

              {:error, changeset} ->
                Mix.shell().error(
                  "✗ Failed to delete #{display_name}: #{inspect(changeset.errors)}"
                )

                {:error, changeset}
            end
          end)

        if Enum.all?(results, &(&1 == :ok)) do
          Mix.shell().info("✓ All admin users deleted successfully")
          :ok
        else
          Mix.shell().error("✗ Some deletions failed")
          exit({:shutdown, 1})
        end
    end
  end
end
