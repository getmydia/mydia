defmodule MydiaWeb.Schema.Resolvers.AuthResolver do
  @moduledoc """
  GraphQL resolvers for authentication operations.
  """

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian
  alias Mydia.Config

  @doc """
  Login with username/password and device information.

  This resolver:
  1. Validates credentials
  2. Creates a JWT token
  3. Returns user info and token

  Note: This does NOT create a device record - that's handled by the remote access flow.
  For direct mode login, we just authenticate and return a token.
  """
  def login(_parent, %{input: input}, %{context: context}) do
    # Check if local auth is enabled
    config = Config.get()

    if config.auth.local_enabled do
      ip_address = Map.get(context, :remote_ip, "unknown")

      case Accounts.check_login_rate_limit(ip_address, input.username) do
        :ok ->
          do_login(input, ip_address)

        {:error, :rate_limited} ->
          {:error, "Too many login attempts. Please try again later."}
      end
    else
      {:error, "Local authentication is disabled"}
    end
  end

  defp do_login(input, ip_address) do
    # Try to find user by username or email
    user =
      case Accounts.get_user_by_username(input.username) do
        nil -> Accounts.get_user_by_email(input.username)
        user -> user
      end

    case user do
      nil ->
        # Don't reveal whether username exists
        Accounts.record_login_failure(ip_address, input.username)
        {:error, "Invalid username or password"}

      user ->
        if Accounts.verify_password(user, input.password) do
          Accounts.reset_login_rate_limit(ip_address, input.username)
          # Update last login timestamp
          Accounts.update_last_login(user)

          # Create JWT token
          case Guardian.create_token(user) do
            {:ok, token, claims} ->
              # Get token expiration (default is 30 days for Guardian)
              expires_in = Map.get(claims, "exp", 0) - Map.get(claims, "iat", 0)

              {:ok,
               %{
                 token: token,
                 user: user,
                 expires_in: expires_in
               }}

            {:error, reason} ->
              {:error, "Failed to create authentication token: #{inspect(reason)}"}
          end
        else
          Accounts.record_login_failure(ip_address, input.username)
          {:error, "Invalid username or password"}
        end
    end
  end
end
