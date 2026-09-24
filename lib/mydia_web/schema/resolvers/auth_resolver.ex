defmodule MydiaWeb.Schema.Resolvers.AuthResolver do
  @moduledoc """
  GraphQL resolvers for authentication operations.
  """

  alias Mydia.Accounts
  alias Mydia.Accounts.User
  alias Mydia.Auth.Guardian
  alias Mydia.Config
  alias Mydia.RemoteAccess

  @totp_challenge_salt "totp challenge"
  @totp_challenge_max_age 300

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
          if Accounts.totp_enabled?(user) do
            {:ok, totp_challenge(user, input)}
          else
            Accounts.reset_login_rate_limit(ip_address, input.username)
            # Update last login timestamp
            Accounts.update_last_login(user)

            issue_login_token(user, input)
          end
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

      {:ok, %{token: token, user: user, expires_in: expires_in, totp_required: false}}
    else
      {:error, %Ecto.Changeset{}} ->
        {:error, "Failed to register this device"}

      {:error, reason} ->
        {:error, "Failed to create authentication token: #{inspect(reason)}"}
    end
  end

  @doc """
  Completes a login that returned `totp_required`. The challenge token carries
  the user and the device fields from the original `login` call, so the device
  row and token are produced exactly as a password-only login would produce them.
  """
  def verify_totp(_parent, %{input: %{challenge_token: token, code: code}}, %{context: context}) do
    if Config.get().auth.local_enabled do
      ip_address = Map.get(context, :remote_ip, "unknown")

      with {:ok, user, device} <- challenge_user(token),
           :ok <- totp_rate_limit(ip_address, user),
           :ok <- second_factor(ip_address, user, code) do
        Accounts.reset_login_rate_limit(ip_address, rate_limit_name(user))
        Accounts.update_last_login(user)
        issue_login_token(user, device)
      end
    else
      {:error, "Local authentication is disabled"}
    end
  end

  defp totp_challenge(user, input) do
    token =
      Phoenix.Token.sign(MydiaWeb.Endpoint, @totp_challenge_salt, %{
        "user_id" => user.id,
        "device_id" => input.device_id,
        "device_name" => input.device_name,
        "platform" => input.platform
      })

    %{totp_required: true, challenge_token: token}
  end

  defp challenge_user(token) do
    with {:ok, claims} <-
           Phoenix.Token.verify(MydiaWeb.Endpoint, @totp_challenge_salt, token,
             max_age: @totp_challenge_max_age
           ),
         %User{} = user <- Accounts.get_user_by_id(claims["user_id"]),
         true <- Accounts.totp_enabled?(user) do
      {:ok, user,
       %{
         device_id: claims["device_id"],
         device_name: claims["device_name"],
         platform: claims["platform"]
       }}
    else
      _ -> {:error, "Sign-in expired, please try again"}
    end
  end

  defp totp_rate_limit(ip_address, user) do
    case Accounts.check_login_rate_limit(ip_address, rate_limit_name(user)) do
      :ok -> :ok
      {:error, :rate_limited} -> {:error, "Too many login attempts. Please try again later."}
    end
  end

  defp second_factor(ip_address, user, code) do
    case Accounts.verify_second_factor(user, code) do
      :ok ->
        :ok

      {:error, :invalid_code} ->
        Accounts.record_login_failure(ip_address, rate_limit_name(user))
        {:error, "Invalid code"}
    end
  end

  # The `login` mutation keys the username bucket on whatever the caller typed,
  # which may be an email. The challenge only knows the account, so it keys on
  # the account's own name.
  defp rate_limit_name(%User{username: username}) when is_binary(username), do: username
  defp rate_limit_name(%User{email: email}), do: email
end
