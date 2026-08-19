defmodule Mydia.RemoteAccess do
  @moduledoc """
  Context module for remote access functionality.
  Manages instance configuration and device pairing for remote access.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.Repo
  alias Mydia.RemoteAccess.{Config, PairingClaim, RemoteDevice}

  # Cache key for the enabled flag. See enabled?/0.
  @enabled_key {__MODULE__, :enabled}

  # Config management

  @doc """
  Creates the remote access configuration with a fresh instance ID.

  Called when remote access is first enabled. The instance ID is a UUID v4
  that uniquely identifies this Mydia instance. The node identity used to
  reach it lives in the iroh keypair file, not here.

  Returns `{:ok, config}`, or `{:error, changeset}` if the insert fails.
  """
  def initialize_config do
    # Enabling remote access is an admin toggle, so two tabs can reach this at
    # once. Each insert would mint its own instance ID, which the unique index
    # on that column cannot collide, leaving two config rows behind.
    case get_config() do
      nil ->
        %Config{}
        # Note: relay_url is read from METADATA_RELAY_URL env var at runtime
        |> Config.changeset(%{instance_id: Ecto.UUID.generate(), enabled: false})
        |> Repo.insert()

      config ->
        {:ok, config}
    end
  end

  @doc """
  Gets the remote access configuration.
  Returns nil if not configured.

  Oldest row wins rather than `Repo.one/1`, which raises on a second row. The
  instance ID is what a paired device was introduced to, so if two rows ever do
  race in, the one devices already know is the one to keep answering with.
  """
  def get_config do
    Repo.one(from c in Config, order_by: [asc: c.inserted_at, asc: c.id], limit: 1)
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
  Whether remote access is enabled on this instance.

  Read from `:persistent_term` rather than the database. This sits on
  request-serving paths (`MydiaWeb.Plugs.MediaAuth`, `MydiaWeb.Plugs.RelayDeviceAuth`
  and the `Mydia.P2p.Server` request handlers), so a query per call is not
  affordable. `:persistent_term` suits a value written a handful of times in a
  server's lifetime and read constantly.

  Fails closed: with no config row there is no instance identity for a remote
  device to authenticate against, so the answer is `false`.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case :persistent_term.get(@enabled_key, :unset) do
      :unset -> refresh_enabled_cache()
      enabled -> enabled
    end
  end

  @doc """
  Re-reads the enabled flag from the database and reseeds the cache.

  Returns the value it stored. Called at boot and by every writer.
  """
  @spec refresh_enabled_cache() :: boolean()
  def refresh_enabled_cache do
    enabled =
      case get_config() do
        nil -> false
        config -> config.enabled
      end

    :persistent_term.put(@enabled_key, enabled)
    enabled
  end

  @doc """
  Creates or updates the remote access configuration.
  Since there should only be one config, this upserts.
  """
  def upsert_config(attrs) do
    result =
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

    with {:ok, config} <- result do
      :persistent_term.put(@enabled_key, config.enabled)
      {:ok, config}
    end
  end

  def toggle_remote_access(enabled) when is_boolean(enabled) do
    case get_config() do
      nil ->
        {:error, :not_configured}

      config ->
        with {:ok, updated} <-
               config
               |> Config.toggle_enabled_changeset(enabled)
               |> Repo.update() do
          :persistent_term.put(@enabled_key, updated.enabled)
          {:ok, updated}
        end
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

  # Throttle interval for device liveness writes (5 minutes)
  @touch_throttle_seconds 300

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
  Records that a device was seen, unless the throttle window has not elapsed.

  Accepts a loaded device or a device id. Returns `:recorded` when it wrote and
  `:skipped` when it did not, which covers both a device seen moments ago and
  one that no longer exists.

  One conditional `UPDATE` rather than a read followed by a write. A p2p player
  holds a GraphQL and an HLS connection at once and they are handled in separate
  processes, so a read-then-write pair lets both sides clear the throttle and
  write together; here the throttle window is part of the statement, so exactly
  one of them matches a row. It also keeps the common throttled case to a single
  statement that touches nothing.
  """
  @spec touch_device_if_stale(RemoteDevice.t() | binary()) :: :recorded | :skipped
  def touch_device_if_stale(%RemoteDevice{id: device_id}), do: touch_device_if_stale(device_id)

  def touch_device_if_stale(device_id) when is_binary(device_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    threshold = DateTime.add(now, -@touch_throttle_seconds, :second)

    query =
      from d in RemoteDevice,
        where: d.id == ^device_id,
        where: is_nil(d.last_seen_at) or d.last_seen_at < ^threshold

    case Repo.update_all(query, set: [last_seen_at: now, updated_at: now]) do
      {0, _} -> :skipped
      {_updated, _} -> :recorded
    end
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
    if enabled?() do
      do_generate_claim_code(user_id)
    else
      {:error, :disabled}
    end
  end

  defp do_generate_claim_code(user_id) do
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
