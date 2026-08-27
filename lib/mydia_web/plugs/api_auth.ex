defmodule MydiaWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates API requests using API keys.

  API keys can be provided via:
  1. X-API-Key header
  2. api_key query parameter

  If valid, the user is loaded and available via Guardian.Plug.current_resource/1.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Mydia.Accounts
  alias Mydia.Accounts.Scope
  alias Mydia.Auth.Guardian

  def init(opts), do: opts

  def call(conn, _opts) do
    # Skip if user is already authenticated via JWT
    case Guardian.Plug.current_resource(conn) do
      nil -> verify_api_key(conn)
      _user -> conn
    end
  end

  defp verify_api_key(conn) do
    case extract_api_key(conn) do
      nil ->
        conn

      api_key ->
        ip_address = get_ip_address(conn)

        # Check rate limit
        case Mydia.Accounts.ApiKeyRateLimiter.check_rate_limit(ip_address) do
          :ok ->
            case Accounts.verify_api_key(api_key) do
              {:ok, user, _api_key_record} ->
                # Reset rate limit on successful authentication
                Mydia.Accounts.ApiKeyRateLimiter.reset_rate_limit(ip_address)
                # Store user in the connection for later use
                conn
                |> Guardian.Plug.put_current_resource(user)
                |> assign(:current_scope, Scope.for_user(user))

              {:error, :invalid_key} ->
                # Record failed attempt
                Mydia.Accounts.ApiKeyRateLimiter.record_failed_attempt(ip_address)

                conn
                |> put_status(401)
                |> json(%{error: "Unauthorized", message: "Invalid API key"})
                |> halt()
            end

          {:error, :rate_limited} ->
            conn
            |> put_status(429)
            |> json(%{error: "Too Many Requests", message: "Rate limit exceeded"})
            |> halt()
        end
    end
  end

  defp extract_api_key(conn) do
    # Check X-API-Key header first
    case get_req_header(conn, "x-api-key") do
      [key | _] ->
        key

      [] ->
        # Fall back to query parameter
        case conn.query_params do
          %{"api_key" => key} -> key
          _ -> nil
        end
    end
  end

  defp get_ip_address(conn) do
    # Get the remote IP address from the connection
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      {a, b, c, d, e, f, g, h} -> "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
      _ -> "unknown"
    end
  end
end
