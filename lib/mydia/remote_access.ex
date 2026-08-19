defmodule Mydia.RemoteAccess do
  @moduledoc """
  Context module for remote access functionality.
  Manages instance configuration and device pairing for remote access.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.Repo
  alias Mydia.RemoteAccess.{Config, PairingClaim, RemoteDevice}

  # Config management

  @doc """
  Initializes the instance keypair and generates a unique instance ID.

  This function should be called when remote access is first enabled.
  It generates a new Noise protocol keypair, encrypts the private key using
  the application secret, and stores both keys along with a unique instance ID.

  Returns {:ok, config} with the initialized configuration, or {:error, changeset}
  if the operation fails.

  ## Security Notes

  - The private key is encrypted using the application's secret_key_base
  - The instance ID is a UUID v4 that uniquely identifies this Mydia instance
  - This should only be called once per instance, typically when enabling remote access

  ## Examples

      iex> {:ok, config} = Mydia.RemoteAccess.initialize_keypair()
      iex> byte_size(config.static_public_key)
      32
      iex> is_binary(config.static_private_key_encrypted)
      true
      iex> is_binary(config.instance_id)
      true

  """
  def initialize_keypair do
    # Generate X25519 keypair for Noise protocol
    {public_key, private_key} = generate_x25519_keypair()

    # Generate a unique instance ID
    instance_id = Ecto.UUID.generate()

    # Create the config with the keypair
    # Note: relay_url is read from METADATA_RELAY_URL env var at runtime
    %Config{}
    |> Config.changeset(%{
      instance_id: instance_id,
      static_public_key: public_key,
      static_private_key_encrypted: encrypt_private_key(private_key),
      enabled: false
    })
    |> Repo.insert()
  end

  @doc """
  Generates an X25519 keypair for the Noise protocol.

  Returns `{public_key, private_key}` as 32-byte binaries.
  """
  def generate_x25519_keypair do
    # Use Erlang crypto to generate a valid X25519 keypair
    :crypto.generate_key(:ecdh, :x25519)
  end

  @doc """
  Gets the public key for the instance.

  Returns the instance's static public key, which can be safely shared with clients
  for configuration and pairing.

  Returns the public key as a 32-byte binary, or nil if not configured.

  ## Examples

      iex> Mydia.RemoteAccess.get_public_key()
      <<1, 2, 3, ...>>  # 32-byte public key

  """
  def get_public_key do
    case get_config() do
      nil -> nil
      config -> config.static_public_key
    end
  end

  @doc """
  Gets the private key for the instance.

  Returns `{:ok, private_key}` where private_key is a 32-byte binary,
  or `{:error, :not_configured}` if not configured.
  """
  def get_private_key do
    case get_config() do
      nil ->
        {:error, :not_configured}

      config ->
        decrypt_private_key(config.static_private_key_encrypted)
    end
  end

  @doc """
  Gets the static keypair for the Noise protocol.

  Returns `{:ok, {public_key, private_key}}` where each key is a 32-byte binary,
  or `{:error, :not_configured}` if not configured.
  """
  @spec get_static_keypair() :: {:ok, {binary(), binary()}} | {:error, :not_configured}
  def get_static_keypair do
    case get_config() do
      nil ->
        {:error, :not_configured}

      config ->
        with {:ok, private_key} <- decrypt_private_key(config.static_private_key_encrypted) do
          {:ok, {config.static_public_key, private_key}}
        end
    end
  end

  @doc """
  Gets the remote access configuration.
  Returns nil if not configured.
  """
  def get_config do
    Repo.one(Config)
  end

  @doc """
  Gets the remote access configuration, raising if not found.
  """
  def get_config! do
    case get_config() do
      nil -> raise Ecto.NoResultsError, queryable: Config
      config -> config
    end
  end

  @doc """
  Creates or updates the remote access configuration.
  Since there should only be one config, this upserts.
  """
  def upsert_config(attrs) do
    case get_config() do
      nil ->
        %Config{}
        |> Config.changeset(attrs)
        |> Repo.insert()

      config ->
        config
        |> Config.changeset(attrs)
        |> Repo.update()
    end
  end

  defp encrypt_private_key(private_key)
       when is_binary(private_key) and byte_size(private_key) == 32 do
    secret_key_base = MydiaWeb.Endpoint.config(:secret_key_base)

    secret =
      Plug.Crypto.KeyGenerator.generate(secret_key_base, "remote_access_private_key", length: 32)

    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, secret, iv, private_key, <<>>, true)

    # Format: version(1) || iv(12) || tag(16) || ciphertext(32)
    <<1, iv::binary, tag::binary, ciphertext::binary>>
  end

  # Versioned v1 format: version(1) || iv(12) || tag(16) || ciphertext(32)
  defp decrypt_private_key(
         <<1, iv::binary-size(12), tag::binary-size(16), ciphertext::binary-size(32)>>
       ) do
    decrypt_private_key(<<iv::binary, tag::binary, ciphertext::binary>>)
  end

  defp decrypt_private_key(
         <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary-size(32)>>
       ) do
    secret_key_base = MydiaWeb.Endpoint.config(:secret_key_base)

    secret =
      Plug.Crypto.KeyGenerator.generate(secret_key_base, "remote_access_private_key", length: 32)

    case :crypto.crypto_one_time_aead(:aes_256_gcm, secret, iv, ciphertext, <<>>, tag, false) do
      :error -> {:error, :invalid_private_key}
      private_key -> {:ok, private_key}
    end
  end

  # Versioned v1 format: version(1) || iv(12) || tag(16) || ciphertext(32)
  defp decrypt_private_key(
         <<1, iv::binary-size(12), tag::binary-size(16), ciphertext::binary-size(32)>>
       ) do
    decrypt_private_key(<<iv::binary, tag::binary, ciphertext::binary>>)
  end

  # Legacy (unencrypted) format
  defp decrypt_private_key(private_key)
       when is_binary(private_key) and byte_size(private_key) == 32 do
    {:ok, private_key}
  end

  defp decrypt_private_key(_), do: {:error, :invalid_private_key}

  def toggle_remote_access(enabled) when is_boolean(enabled) do
    case get_config() do
      nil ->
        {:error, :not_configured}

      config ->
        config
        |> Config.toggle_enabled_changeset(enabled)
        |> Repo.update()
    end
  end

  # Device management

  @doc """
  Lists all paired devices for a user.
  """
  def list_devices(user_id) do
    RemoteDevice
    |> where([d], d.user_id == ^user_id)
    |> order_by([d], desc: d.inserted_at)
    |> Repo.all()
  end

  @doc """
  Lists all active (non-revoked) devices for a user.
  """
  def list_active_devices(user_id) do
    RemoteDevice
    |> where([d], d.user_id == ^user_id and is_nil(d.revoked_at))
    |> order_by([d], desc: d.last_seen_at)
    |> Repo.all()
  end

  @doc """
  Gets a device by ID.
  """
  def get_device(id) do
    Repo.get(RemoteDevice, id)
  end

  @doc """
  Gets a device by ID, raising if not found.
  """
  def get_device!(id) do
    Repo.get!(RemoteDevice, id)
  end

  @doc """
  Gets an active (non-revoked) device by ID, preloading the user.

  Returns `{:ok, device}` if found and active.
  Returns `{:error, :not_found}` if device doesn't exist.
  Returns `{:error, :revoked}` if device is revoked.
  """
  @spec get_active_device(String.t()) :: {:ok, RemoteDevice.t()} | {:error, :not_found | :revoked}
  def get_active_device(device_id) do
    case Repo.get(RemoteDevice, device_id) |> Repo.preload(:user) do
      nil ->
        {:error, :not_found}

      device ->
        if RemoteDevice.revoked?(device) do
          {:error, :revoked}
        else
          {:ok, device}
        end
    end
  end

  @doc """
  Gets a device by token hash.
  """
  def get_device_by_token_hash(token_hash) do
    Repo.get_by(RemoteDevice, token_hash: token_hash)
  end

  @doc """
  Verifies a device token and returns the device if valid.

  This function checks the provided token against all non-revoked devices
  using Argon2 verification. Returns `{:ok, device}` if found, `{:error, :not_found}` otherwise.

  Note: This iterates through devices which may be slow with many devices.
  Consider adding a token lookup field for better performance at scale.
  """
  def verify_device_token(token) when is_binary(token) do
    # Get all non-revoked devices
    query =
      from d in RemoteDevice,
        where: is_nil(d.revoked_at),
        select: d

    devices = Repo.all(query)

    # Find the device whose token_hash matches
    case Enum.find(devices, fn device ->
           device.token_hash && Argon2.verify_pass(token, device.token_hash)
         end) do
      nil -> {:error, :not_found}
      device -> {:ok, device}
    end
  end

  def verify_device_token(_), do: {:error, :not_found}

  @doc """
  Creates a new device pairing.
  """
  def create_device(attrs) do
    %RemoteDevice{}
    |> RemoteDevice.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates the last seen timestamp for a device.
  """
  def touch_device(device) do
    device
    |> RemoteDevice.seen_changeset()
    |> Repo.update()
  end

  # Throttle interval for touch_device_async (5 minutes)
  @touch_throttle_seconds 300

  @doc """
  Asynchronously updates the last seen timestamp for a device if needed.

  This function throttles updates to avoid hitting the database on every request.
  The timestamp is only updated if:
  - `last_seen_at` is nil (device never seen)
  - `last_seen_at` is older than #{@touch_throttle_seconds} seconds

  The update runs asynchronously to avoid blocking the request.
  """
  def touch_device_async(device) do
    if should_touch_device?(device) do
      Task.start(fn -> touch_device(device) end)
    end

    :ok
  end

  @doc """
  Records liveness for the device named in a verified access token's claims.

  The remote access admin page derives "online" entirely from `last_seen_at`,
  so without this a player streaming over p2p right now still reads as never
  connected. Claims without a `"device_id"` (a plain user login rather than a
  paired device) are ignored.
  """
  def touch_device_from_claims(%{"device_id" => device_id}) when is_binary(device_id) do
    touch_device_if_stale(device_id)
    :ok
  end

  def touch_device_from_claims(_claims), do: :ok

  @doc """
  Updates `last_seen_at` unless it was already written inside the throttle window.

  Accepts a loaded device or a device id. Synchronous: callers on a request path
  are already holding a database connection, and the throttle keeps this to one
  write per device per #{@touch_throttle_seconds} seconds.
  """
  def touch_device_if_stale(device_id) when is_binary(device_id) do
    case get_device(device_id) do
      nil -> {:error, :not_found}
      device -> touch_device_if_stale(device)
    end
  end

  def touch_device_if_stale(%RemoteDevice{} = device) do
    if should_touch_device?(device) do
      touch_device(device)
    else
      {:ok, device}
    end
  end

  defp should_touch_device?(%{last_seen_at: nil}), do: true

  defp should_touch_device?(%{last_seen_at: last_seen_at}) do
    threshold = DateTime.utc_now() |> DateTime.add(-@touch_throttle_seconds, :second)
    DateTime.compare(last_seen_at, threshold) == :lt
  end

  @doc """
  Revokes a device, preventing future access.
  """
  def revoke_device(device) do
    case device
         |> RemoteDevice.revoke_changeset()
         |> Repo.update() do
      {:ok, updated_device} = result ->
        # Publish device status change event
        publish_device_event(updated_device, :revoked)
        result

      error ->
        error
    end
  end

  @doc """
  Deletes a device completely.
  """
  def delete_device(device) do
    case Repo.delete(device) do
      {:ok, deleted_device} = result ->
        # Publish device status change event
        publish_device_event(deleted_device, :deleted)
        result

      error ->
        error
    end
  end

  # Claim code management

  @doc """
  Generates a new pairing claim code for a user.
  The code expires after 5 minutes.

  This function:
  1. Gets the P2P server's node_addr
  2. Posts the node_addr to the relay to get a claim code
  3. Creates a local claim record

  Returns {:ok, claim} if successful, {:error, reason} otherwise.
  """
  def generate_claim_code(user_id) do
    # Get the P2P server's node address
    with {:ok, node_addr} <- get_p2p_node_addr(),
         {:ok, %{"claim_code" => code}} <- create_pairing_claim(node_addr) do
      # Calculate expiration (5 minutes from now)
      expires_at =
        DateTime.utc_now()
        |> DateTime.add(300, :second)
        |> DateTime.truncate(:second)

      # Store local claim record
      {:ok, claim} =
        %PairingClaim{}
        |> PairingClaim.changeset_with_code(%{
          user_id: user_id,
          code: code,
          expires_at: expires_at
        })
        |> Repo.insert()

      Logger.debug("Claim code #{code} created with node_addr")

      {:ok, claim}
    end
  end

  defp get_p2p_node_addr do
    case p2p_status() do
      {:ok, %{node_addr: node_addr}} when is_binary(node_addr) and node_addr != "" ->
        {:ok, node_addr}

      {:ok, %{running: true}} ->
        fetch_live_node_addr()

      _ ->
        {:error, :p2p_not_ready}
    end
  end

  defp fetch_live_node_addr do
    try do
      case Mydia.P2p.Server.get_node_addr() do
        node_addr when is_binary(node_addr) and node_addr != "" ->
          {:ok, node_addr}

        _ ->
          {:error, :p2p_not_ready}
      end
    rescue
      _ ->
        {:error, :p2p_not_ready}
    catch
      :exit, _ ->
        {:error, :p2p_not_ready}
    end
  end

  defp create_pairing_claim(node_addr) do
    url = "#{get_relay_url()}/pairing/claim"

    body = %{node_addr: node_addr}

    case Req.post(url, json: body) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Create pairing claim failed: #{status} - #{inspect(body)}")
        {:error, :create_claim_failed}

      {:error, reason} ->
        Logger.error("Create pairing claim error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_relay_url do
    System.get_env("METADATA_RELAY_URL") || System.get_env("RELAY_URL") ||
      "https://relay.mydia.dev"
  end

  @doc """
  Cleans up stale local claims on startup.
  Called by startup task.

  With the new /pairing/claim API, claims are ephemeral on the relay side.
  We just need to clean up expired local claims.
  """
  def resume_active_claims do
    # Clean up expired claims
    {:ok, count} = cleanup_expired_claims()

    if count > 0 do
      Logger.info("Cleaned up #{count} expired pairing claims on startup")
    end

    :ok
  end

  @doc """
  Validates a claim code with rate limiting.
  Returns {:ok, claim} if the code is valid (exists, not expired, not used).
  Returns {:error, reason} otherwise.

  Optional `ip_address` parameter enables rate limiting.
  """
  def validate_claim_code(code, opts \\ []) do
    ip_address = Keyword.get(opts, :ip_address)

    # Check rate limit if IP address is provided
    if ip_address do
      case Mydia.RemoteAccess.ClaimRateLimiter.check_rate_limit(ip_address) do
        :ok ->
          do_validate_claim_code(code, ip_address)

        {:error, :rate_limited} = error ->
          error
      end
    else
      do_validate_claim_code(code, nil)
    end
  end

  defp do_validate_claim_code(code, ip_address) do
    code = normalize_code(code)

    result =
      case get_claim_by_code(code) do
        nil ->
          {:error, :not_found}

        claim ->
          cond do
            PairingClaim.used?(claim) ->
              {:error, :already_used}

            PairingClaim.expired?(claim) ->
              {:error, :expired}

            true ->
              {:ok, claim}
          end
      end

    # Record failed attempt if IP address is provided
    if ip_address do
      case result do
        {:ok, _claim} ->
          Mydia.RemoteAccess.ClaimRateLimiter.reset_rate_limit(ip_address)

        {:error, _reason} ->
          Mydia.RemoteAccess.ClaimRateLimiter.record_failed_attempt(ip_address)
      end
    end

    result
  end

  @doc """
  Consumes a claim code, marking it as used and linking it to a device.
  Returns {:ok, claim} if successful.
  Returns {:error, reason} if the claim is invalid.
  """
  def consume_claim_code(code, device_id) do
    code = normalize_code(code)

    with {:ok, claim} <- validate_claim_code(code),
         {:ok, consumed_claim} <-
           claim |> PairingClaim.consume_changeset(device_id) |> Repo.update() do
      # Notify UI that claim has been consumed (for auto-closing pairing modal)
      publish_claim_consumed(consumed_claim)
      {:ok, consumed_claim}
    end
  end

  @doc """
  Cleans up expired claim codes.
  Deletes all claims that have expired and have not been used.
  Returns {:ok, count} where count is the number of deleted claims.
  """
  def cleanup_expired_claims do
    now = DateTime.utc_now()

    {count, _} =
      PairingClaim
      |> where([c], c.expires_at < ^now)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Gets a claim by its code.
  Returns nil if not found.
  """
  def get_claim_by_code(code) do
    code = normalize_code(code)
    Repo.get_by(PairingClaim, code: code)
  end

  @doc """
  Lists all active (non-expired, non-used) claims for a user.
  """
  def list_active_claims(user_id) do
    now = DateTime.utc_now()

    PairingClaim
    |> where([c], c.user_id == ^user_id)
    |> where([c], is_nil(c.used_at))
    |> where([c], c.expires_at > ^now)
    |> order_by([c], desc: c.inserted_at)
    |> Repo.all()
  end

  # Normalize claim code by removing whitespace and dashes, converting to uppercase
  # This only cleans user input - it doesn't re-add dashes since relay generates
  # codes without dashes and stores them as-is
  defp normalize_code(code) do
    code
    |> String.replace(~r/[\s-]/, "")
    |> String.upcase()
  end

  # P2p service management

  @doc """
  Gets the status of the iroh-based p2p host.

  Returns {:ok, status} with a map containing:
  - node_id: The node's public key / endpoint ID
  - node_addr: The node's EndpointAddr as JSON (for sharing)
  - running: Whether the host is running
  - connected_peers: Number of connected peers
  - relay_connected: Whether connected to a relay server
  """
  def p2p_status do
    try do
      status = Mydia.P2p.Server.status()
      {:ok, status}
    rescue
      _ ->
        {:ok,
         %Mydia.P2p.Server.Status{
           node_id: nil,
           node_addr: nil,
           running: false,
           connected_peers: 0,
           relay_connected: false
         }}
    catch
      :exit, _ ->
        {:ok,
         %Mydia.P2p.Server.Status{
           node_id: nil,
           node_addr: nil,
           running: false,
           connected_peers: 0,
           relay_connected: false
         }}
    end
  end

  @doc """
  Checks if the iroh-based p2p service is available and running.
  """
  def p2p_available? do
    case p2p_status() do
      {:ok, %{running: true}} -> true
      _ -> false
    end
  end

  @doc """
  Gets network statistics from the iroh-based p2p host.

  Returns {:ok, stats} with:
  - connected_peers: Number of currently connected peers
  - relay_connected: Whether connected to a relay server
  """
  def network_stats do
    try do
      stats = Mydia.P2p.Server.network_stats()
      {:ok, stats}
    rescue
      _ ->
        {:ok,
         %Mydia.P2p.NetworkStats{
           connected_peers: 0,
           relay_connected: false
         }}
    catch
      :exit, _ ->
        {:ok,
         %Mydia.P2p.NetworkStats{
           connected_peers: 0,
           relay_connected: false
         }}
    end
  end

  @doc """
  Updates the instance's direct URLs and certificate fingerprint.
  """
  def update_direct_urls(direct_urls, cert_fingerprint, _notify_relay? \\ true)
      when is_list(direct_urls) and is_binary(cert_fingerprint) do
    # Update the config
    upsert_config(%{
      direct_urls: direct_urls,
      cert_fingerprint: cert_fingerprint
    })
  end

  @doc """
  Refreshes the instance's direct URLs by auto-detecting them.
  This detects all available network interfaces and updates the stored URLs.

  Returns {:ok, config} with the updated configuration, or {:error, reason}.

  ## Examples

      iex> refresh_direct_urls()
      {:ok, %Config{direct_urls: ["https://192-168-1-100.sslip.io:4000"], ...}}

  """
  def refresh_direct_urls do
    # Auto-detect direct URLs
    direct_urls = Mydia.RemoteAccess.DirectUrls.detect_all()

    # Ensure certificate exists and get fingerprint
    case Mydia.RemoteAccess.Certificates.ensure_certificate() do
      {:ok, _cert_path, _key_path, fingerprint} ->
        update_direct_urls(direct_urls, fingerprint)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Starts the relay connection process.
  """
  def start_relay do
    :ok
  end

  @doc """
  Stops the relay connection process.
  """
  def stop_relay do
    :ok
  end

  # Subscription helpers

  @doc """
  Publishes a device status change event to GraphQL subscriptions.
  """
  def publish_device_event(device, event_type)
      when event_type in [:connected, :disconnected, :revoked, :deleted] do
    event_payload = %{
      device: format_device_for_subscription(device),
      event: event_type
    }

    Absinthe.Subscription.publish(
      MydiaWeb.Endpoint,
      event_payload,
      device_status_changed: "device_status:#{device.user_id}"
    )
  end

  @doc """
  Publishes a claim consumed event via PubSub.
  Used to notify the UI that a pairing code has been used and the modal should close.
  """
  def publish_claim_consumed(claim) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "remote_access:claims",
      {:claim_consumed, %{code: claim.code, user_id: claim.user_id}}
    )
  end

  # Format device struct for subscription payload
  defp format_device_for_subscription(device) do
    %{
      id: device.id,
      device_name: device.device_name,
      platform: device.platform,
      last_seen_at: device.last_seen_at,
      revoked_at: device.revoked_at,
      inserted_at: device.inserted_at
    }
  end
end
