defmodule MydiaWeb.Schema.Resolvers.AuthResolver do
  @moduledoc """
  GraphQL resolvers for authentication operations.
  """

  alias Mydia.Accounts
  alias Mydia.Auth.Guardian
  alias Mydia.Config
  alias Mydia.RemoteAccess

  @doc """
  Login with username/password and device information.

  This resolver:
  1. Validates credentials
  2. Finds or creates the caller's `RemoteDevice` row and mints a device-scoped token
  3. Returns user info and token

  The device row is what `registerDeviceNode` keys on, so a password login has
  to produce one just like pairing does, or the device that logged in this way
  can never publish its iroh node id.
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

          issue_login_token(user, input)
        else
          Accounts.record_login_failure(ip_address, input.username)
          {:error, "Invalid username or password"}
        end
    end
  end

  # A password login must end with a device row and a `device_id` claim, the
  # same shape pairing produces. Without them `registerDeviceNode` rejects the
  # caller, the device never publishes its iroh node id, and it stays invisible
  # to every other device on the account. The `login_input` fields this needs
  # have been required by the schema all along and were previously discarded.
  defp issue_login_token(user, input) do
    with {:ok, device} <-
           RemoteAccess.find_or_create_login_device(%{
             user_id: user.id,
             client_device_id: input.device_id,
             device_name: input.device_name,
             platform: input.platform
           }),
         {:ok, token, claims} <-
           Guardian.encode_and_sign(user, %{"device_id" => device.id, "typ" => "access"}) do
      expires_in = Map.get(claims, "exp", 0) - Map.get(claims, "iat", 0)

      {:ok, %{token: token, user: user, expires_in: expires_in}}
    else
      {:error, %Ecto.Changeset{}} ->
        {:error, "Failed to register this device"}

      {:error, reason} ->
        {:error, "Failed to create authentication token: #{inspect(reason)}"}
    end
  end
end
