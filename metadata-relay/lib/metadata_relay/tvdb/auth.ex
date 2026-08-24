defmodule MetadataRelay.TVDB.Auth do
  @moduledoc """
  GenServer that manages TVDB JWT authentication tokens.

  This module handles:
  - Initial authentication with TVDB API
  - Token caching in GenServer state
  - Automatic token refresh before expiration
  - Graceful error handling for authentication failures

  The GenServer is supervised and will automatically restart on failure.

  ## Testing

  For testing, you can configure a custom HTTP adapter via application config:

      config :metadata_relay, :tvdb_http_adapter, fn request ->
        {request, Req.Response.new(status: 200, body: %{"data" => %{"token" => "test_token"}})}
      end

  """

  use GenServer
  require Logger

  alias MetadataRelay.ReqAdapter

  @auth_url "https://api4.thetvdb.com/v4/login"
  # Refresh token 1 hour before expiration (tokens typically last 30 days)
  @refresh_before_expiry :timer.hours(1)

  ## Client API

  @doc """
  Starts the TVDB Auth GenServer.

  Options:
    - `:name` - The name to register the GenServer under (default: `__MODULE__`)
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Gets the current valid JWT token.

  Returns `{:ok, token}` if authenticated, or `{:error, reason}` if authentication failed.
  """
  def get_token do
    GenServer.call(__MODULE__, :get_token)
  end

  @doc """
  Forces a token refresh.

  Useful for testing or recovering from authentication errors.
  """
  def refresh_token do
    GenServer.call(__MODULE__, :refresh_token)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Attempt initial authentication on startup
    case authenticate() do
      {:ok, token, expires_at} ->
        schedule_refresh(expires_at)
        {:ok, %{token: token, expires_at: expires_at}}

      {:error, reason} ->
        Logger.error("Failed to authenticate with TVDB: #{inspect(reason)}")
        # Return error and let supervisor handle restart
        {:stop, {:authentication_failed, reason}}
    end
  end

  @impl true
  def handle_call(:get_token, _from, %{token: token} = state) do
    {:reply, {:ok, token}, state}
  end

  @impl true
  def handle_call(:refresh_token, _from, _state) do
    case authenticate() do
      {:ok, token, expires_at} ->
        schedule_refresh(expires_at)
        {:reply, {:ok, token}, %{token: token, expires_at: expires_at}}

      {:error, reason} ->
        Logger.error("Failed to refresh TVDB token: #{inspect(reason)}")
        {:reply, {:error, reason}, %{token: nil, expires_at: nil}}
    end
  end

  @impl true
  def handle_info(:refresh_token, _state) do
    case authenticate() do
      {:ok, token, expires_at} ->
        Logger.info("Successfully refreshed TVDB token")
        schedule_refresh(expires_at)
        {:noreply, %{token: token, expires_at: expires_at}}

      {:error, reason} ->
        Logger.error("Failed to refresh TVDB token: #{inspect(reason)}")
        # Keep old state and retry in 5 minutes
        Process.send_after(self(), :refresh_token, :timer.minutes(5))
        {:noreply, %{token: nil, expires_at: nil}}
    end
  end

  ## Private Functions

  defp authenticate do
    api_key = get_api_key()

    body = %{apikey: api_key}

    request =
      [json: body]
      |> Req.new()
      |> ReqAdapter.attach(Application.get_env(:metadata_relay, :tvdb_http_adapter))

    case Req.post(request, url: @auth_url) do
      {:ok, %{status: 200, body: %{"data" => %{"token" => token}}}} ->
        # Parse JWT to get expiration time
        expires_at = parse_token_expiry(token)
        Logger.info("Successfully authenticated with TVDB, token expires at #{expires_at}")
        {:ok, token, expires_at}

      {:ok, %{status: status, body: body}} ->
        Logger.error("TVDB authentication failed with status #{status}: #{inspect(body)}")
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        Logger.error("TVDB authentication request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_api_key do
    case System.get_env("TVDB_API_KEY") do
      nil ->
        raise RuntimeError, """
        TVDB_API_KEY environment variable is not set.
        Please set it to your TVDB API key.
        """

      key ->
        key
    end
  end

  defp parse_token_expiry(token) do
    # JWT tokens are base64 encoded with format: header.payload.signature
    # We need to decode the payload to get the expiration time
    case String.split(token, ".") do
      [_header, payload, _signature] ->
        case Base.url_decode64(payload, padding: false) do
          {:ok, decoded} ->
            case Jason.decode(decoded) do
              {:ok, %{"exp" => exp}} ->
                # exp is Unix timestamp in seconds
                DateTime.from_unix!(exp)

              _ ->
                # If we can't parse expiration, assume 30 days from now
                DateTime.utc_now() |> DateTime.add(30, :day)
            end

          _ ->
            DateTime.utc_now() |> DateTime.add(30, :day)
        end

      _ ->
        DateTime.utc_now() |> DateTime.add(30, :day)
    end
  end

  defp schedule_refresh(expires_at) do
    # Calculate when to refresh (1 hour before expiration)
    refresh_at = DateTime.add(expires_at, -@refresh_before_expiry, :millisecond)
    now = DateTime.utc_now()

    delay =
      case DateTime.diff(refresh_at, now, :millisecond) do
        diff when diff > 0 -> diff
        # If already expired or very close, refresh in 1 minute
        _ -> :timer.minutes(1)
      end

    Process.send_after(self(), :refresh_token, delay)
  end
end
