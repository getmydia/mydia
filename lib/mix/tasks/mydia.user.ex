defmodule Mix.Tasks.Mydia.User do
  @moduledoc """
  Manages users from the command line.

  ## Commands

  ### List users

      mix mydia.user list
      mix mydia.user list --role=admin

  ### Add a user

      mix mydia.user add <email> <username> [options]

  Options:
    --password=PASSWORD  Set password (required for local auth users)
    --role=ROLE          Set role: admin, user, readonly, guest (default: user)
    --display-name=NAME  Set display name

  ### Delete a user

      mix mydia.user delete <email_or_username>

  ### Reset password

      mix mydia.user reset-password <email_or_username> [options]

  Options:
    --password=PASSWORD  New password (will prompt if not provided)

  ### Reset two-factor authentication

      mix mydia.user reset-2fa <email_or_username>

  Turns off TOTP and deletes the user's recovery codes, for someone who lost
  their authenticator. They sign in with their password alone until they set
  it up again.

  ## Examples

      mix mydia.user list
      mix mydia.user list --role=admin
      mix mydia.user add user@example.com myuser --password=secret123 --role=admin
      mix mydia.user delete user@example.com
      mix mydia.user reset-password admin --password=newpassword
      mix mydia.user reset-2fa admin

  """
  use Mix.Task

  @shortdoc "Manages users (list, add, delete, reset-password, reset-2fa)"

  @valid_roles ~w(admin user readonly guest)

  @impl Mix.Task
  def run(args) do
    # Suppress verbose startup output for CLI commands
    suppress_startup_output()
    Mix.Task.run("app.start")
    restore_output()

    case args do
      ["list" | rest] -> list_users(rest)
      ["add" | rest] -> add_user(rest)
      ["delete" | rest] -> delete_user(rest)
      ["reset-password" | rest] -> reset_password(rest)
      ["reset-2fa" | rest] -> reset_2fa(rest)
      _ -> show_usage()
    end
  end

  defp list_users(args) do
    alias Mydia.Accounts

    {opts, _} = OptionParser.parse!(args, strict: [role: :string])

    filter_opts =
      case opts[:role] do
        nil -> []
        role -> [role: role]
      end

    users = Accounts.list_users(filter_opts)

    if Enum.empty?(users) do
      Mix.shell().info("No users found.")
    else
      Mix.shell().info("")
      Mix.shell().info("Users (#{length(users)}):")
      Mix.shell().info(String.duplicate("-", 80))

      Enum.each(users, fn user ->
        auth_type = if user.oidc_sub, do: "OIDC", else: "Local"
        display = user.display_name || user.username || "-"

        Mix.shell().info(
          "  #{user.email || "-"} | #{user.username || "-"} | #{user.role} | #{auth_type} | #{display}"
        )
      end)

      Mix.shell().info(String.duplicate("-", 80))
      Mix.shell().info("")
    end
  end

  defp add_user(args) do
    alias Mydia.Accounts

    {opts, positional} =
      OptionParser.parse!(args,
        strict: [password: :string, role: :string, display_name: :string]
      )

    case positional do
      [email, username] ->
        role = opts[:role] || "user"

        unless role in @valid_roles do
          Mix.shell().error("✗ Invalid role: #{role}")
          Mix.shell().error("  Valid roles: #{Enum.join(@valid_roles, ", ")}")
          exit({:shutdown, 1})
        end

        password = opts[:password] || prompt_password("Enter password: ")

        if String.length(password) < 8 do
          Mix.shell().error("✗ Password must be at least 8 characters")
          exit({:shutdown, 1})
        end

        attrs = %{
          email: email,
          username: username,
          password: password,
          password_confirmation: password,
          role: role,
          display_name: opts[:display_name]
        }

        case Accounts.create_user(attrs) do
          {:ok, user} ->
            Mix.shell().info("✓ User created successfully")
            Mix.shell().info("  Email:    #{user.email}")
            Mix.shell().info("  Username: #{user.username}")
            Mix.shell().info("  Role:     #{user.role}")

          {:error, changeset} ->
            Mix.shell().error("✗ Failed to create user:")
            format_errors(changeset)
            exit({:shutdown, 1})
        end

      _ ->
        Mix.shell().error("Usage: mix mydia.user add <email> <username> [options]")
        exit({:shutdown, 1})
    end
  end

  defp delete_user(args) do
    alias Mydia.Accounts

    case args do
      [identifier] ->
        user = find_user(identifier)

        if user do
          display = user.email || user.username

          case Accounts.delete_user(user) do
            {:ok, _} ->
              Mix.shell().info("✓ User deleted: #{display}")

            {:error, changeset} ->
              Mix.shell().error("✗ Failed to delete user:")
              format_errors(changeset)
              exit({:shutdown, 1})
          end
        else
          Mix.shell().error("✗ User not found: #{identifier}")
          exit({:shutdown, 1})
        end

      _ ->
        Mix.shell().error("Usage: mix mydia.user delete <email_or_username>")
        exit({:shutdown, 1})
    end
  end

  defp reset_password(args) do
    alias Mydia.Accounts

    {opts, positional} = OptionParser.parse!(args, strict: [password: :string])

    case positional do
      [identifier] ->
        user = find_user(identifier)

        if user do
          if user.oidc_sub && !user.password_hash do
            Mix.shell().error("✗ Cannot set password for OIDC-only user: #{identifier}")
            Mix.shell().error("  This user authenticates via OIDC and has no local password.")
            exit({:shutdown, 1})
          end

          password = opts[:password] || prompt_password("Enter new password: ")

          if String.length(password) < 8 do
            Mix.shell().error("✗ Password must be at least 8 characters")
            exit({:shutdown, 1})
          end

          case Accounts.update_password(user, password) do
            {:ok, _} ->
              display = user.email || user.username
              Mix.shell().info("✓ Password updated for: #{display}")

            {:error, changeset} ->
              Mix.shell().error("✗ Failed to update password:")
              format_errors(changeset)
              exit({:shutdown, 1})
          end
        else
          Mix.shell().error("✗ User not found: #{identifier}")
          exit({:shutdown, 1})
        end

      _ ->
        Mix.shell().error(
          "Usage: mix mydia.user reset-password <email_or_username> [--password=pw]"
        )

        exit({:shutdown, 1})
    end
  end

  defp reset_2fa(args) do
    alias Mydia.Accounts

    case args do
      [identifier] ->
        case find_user(identifier) do
          nil ->
            Mix.shell().error("✗ User not found: #{identifier}")
            exit({:shutdown, 1})

          user ->
            display = user.email || user.username

            if Accounts.second_factor_enabled?(user) do
              {:ok, _} = Accounts.admin_reset_second_factors(user)
              Mix.shell().info("✓ Two-factor authentication turned off for: #{display}")
            else
              Mix.shell().info("#{display} does not have two-factor authentication enabled")
            end
        end

      _ ->
        Mix.shell().error("Usage: mix mydia.user reset-2fa <email_or_username>")
        exit({:shutdown, 1})
    end
  end

  defp find_user(identifier) do
    alias Mydia.Accounts

    # Try email first, then username
    Accounts.get_user_by_email(identifier) || Accounts.get_user_by_username(identifier)
  end

  defp prompt_password(prompt) do
    Mix.shell().info(prompt)
    password = IO.gets("") |> String.trim()

    if password == "" do
      Mix.shell().error("✗ Password cannot be empty")
      exit({:shutdown, 1})
    end

    password
  end

  defp format_errors(changeset) do
    Enum.each(changeset.errors, fn {field, {msg, _}} ->
      Mix.shell().error("  #{field}: #{msg}")
    end)
  end

  defp show_usage do
    Mix.shell().info(@moduledoc)
  end

  # Suppress verbose logger and IO output during app startup
  defp suppress_startup_output do
    # Set environment variable to signal CLI mode to the application
    # This allows startup code to skip verbose logging
    System.put_env("MYDIA_CLI_MODE", "true")

    # Capture IO output during startup (for IO.puts calls in application.ex)
    {:ok, string_io} = StringIO.open("")
    Process.put(:original_group_leader, Process.group_leader())
    Process.put(:string_io, string_io)
    Process.group_leader(self(), string_io)
  end

  # Restore normal output after startup
  defp restore_output do
    # Restore group leader (IO output)
    case Process.get(:original_group_leader) do
      nil -> :ok
      group_leader -> Process.group_leader(self(), group_leader)
    end

    # Close the StringIO to free resources
    case Process.get(:string_io) do
      nil -> :ok
      string_io -> StringIO.close(string_io)
    end

    :ok
  end
end
