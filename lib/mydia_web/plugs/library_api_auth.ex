defmodule MydiaWeb.Plugs.LibraryApiAuth do
  @moduledoc """
  Authenticates a Library API request from the `x-api-key` header.

  Deliberately narrower than `MydiaWeb.Plugs.ApiAuth`, which this does not use:
  a session, a Guardian bearer token, a media token, and the `api_key` query
  parameter are all refused. A query string reaches proxy and access logs, and
  the Library API can add and remove media, so only a key sent as a header is
  accepted.

  The failure counter is shared with the player API's limiter but namespaced
  under its own bucket, so guesses here cannot lock a player out and vice versa.
  Only a failed lookup is charged; a valid key that lacks the scope is not a
  guess.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Mydia.Accounts
  alias Mydia.Accounts.ApiKeyRateLimiter
  alias Mydia.LibraryApi.Principal

  @header "x-api-key"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case get_req_header(conn, @header) do
      [key | _] -> authenticate(conn, key)
      [] -> unauthorized(conn, "Missing API key")
    end
  end

  defp authenticate(conn, key) do
    bucket = "library_api:#{ip(conn)}"

    case ApiKeyRateLimiter.check_rate_limit(bucket) do
      {:error, :rate_limited} ->
        conn
        |> put_status(429)
        |> json(%{error: "Too Many Requests", message: "Rate limit exceeded"})
        |> halt()

      :ok ->
        verify(conn, key, bucket)
    end
  end

  # The environment key short-circuits: it is not a database row, so there is
  # nothing to look up and no Argon2 work to do.
  defp verify(conn, key, bucket) do
    configured = Application.get_env(:mydia, :library_api_key)

    if is_binary(configured) and Plug.Crypto.secure_compare(key, configured) do
      ApiKeyRateLimiter.reset_rate_limit(bucket)

      assign(
        conn,
        :library_api_principal,
        %Principal{role: "admin", source: :env, user: nil, api_key_id: nil}
      )
    else
      verify_database_key(conn, key, bucket)
    end
  end

  defp verify_database_key(conn, key, bucket) do
    case Accounts.verify_api_key(key) do
      {:ok, user, api_key} ->
        if "admin" in (api_key.permissions || []) and user.role == "admin" do
          ApiKeyRateLimiter.reset_rate_limit(bucket)

          assign(
            conn,
            :library_api_principal,
            %Principal{
              role: user.role,
              source: :api_key,
              user: user,
              api_key_id: api_key.id
            }
          )
        else
          # A real key that lacks the scope is not a failed guess, so it does
          # not count against the limiter.
          forbidden(conn, "This key cannot use the Library API")
        end

      {:error, :invalid_key} ->
        ApiKeyRateLimiter.record_failed_attempt(bucket)
        unauthorized(conn, "Invalid API key")
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_status(401)
    |> json(%{error: "Unauthorized", message: message})
    |> halt()
  end

  defp forbidden(conn, message) do
    conn
    |> put_status(403)
    |> json(%{error: "Forbidden", message: message})
    |> halt()
  end

  defp ip(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      {a, b, c, d, e, f, g, h} -> "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
      _ -> "unknown"
    end
  end
end
