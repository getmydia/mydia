defmodule Mydia.MediaServer.PlexOAuth do
  @moduledoc """
  Handles Plex PIN-based OAuth authentication flow.

  This module implements the Plex authentication flow:
  1. Create a PIN using `create_pin/0`
  2. Direct user to the auth URL from `get_auth_url/2`
  3. Poll `check_pin/1` until the user authorizes
  4. Use `list_servers/1` to discover user's Plex servers
  """

  require Logger

  @plex_api_base "https://plex.tv/api/v2"
  @plex_auth_base "https://app.plex.tv/auth#"

  # Client identifier should be consistent for the app
  @client_identifier "mydia-media-manager"
  @product_name "Mydia"

  @type pin_response :: %{id: integer(), code: String.t()}
  @type auth_result :: {:ok, %{auth_token: String.t()}} | :pending | {:error, term()}
  @type server :: %{
          name: String.t(),
          client_identifier: String.t(),
          machine_identifier: String.t(),
          access_token: String.t() | nil,
          provides: String.t(),
          owned: boolean(),
          presence: boolean(),
          connections: [connection()]
        }
  @type connection :: %{
          uri: String.t(),
          protocol: String.t(),
          address: String.t(),
          port: integer(),
          local: boolean(),
          relay: boolean()
        }

  @doc """
  Creates a new PIN for Plex authentication.

  Returns `{:ok, %{id: pin_id, code: code}}` on success.
  The `id` should be stored to poll for completion.
  The `code` is used in the authorization URL.
  """
  @spec create_pin() :: {:ok, pin_response()} | {:error, term()}
  def create_pin do
    url = "#{@plex_api_base}/pins"

    body =
      URI.encode_query(%{
        "strong" => "true",
        "X-Plex-Product" => @product_name,
        "X-Plex-Client-Identifier" => @client_identifier
      })

    headers = [
      {"Content-Type", "application/x-www-form-urlencoded"},
      {"Accept", "application/json"}
    ]

    case Req.post(url, body: body, headers: headers) do
      {:ok, %{status: 201, body: body}} ->
        {:ok, %{id: body["id"], code: body["code"]}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to create Plex PIN: HTTP #{status}", body: inspect(body))
        {:error, "Failed to create PIN: HTTP #{status}"}

      {:error, exception} ->
        Logger.error("Failed to create Plex PIN: #{Exception.message(exception)}")
        {:error, "Network error: #{Exception.message(exception)}"}
    end
  end

  @doc """
  Checks the status of a PIN to see if the user has authorized.

  Returns:
  - `{:ok, %{auth_token: token}}` when the user has authorized
  - `:pending` when the user hasn't authorized yet
  - `{:error, reason}` on failure or expiration
  """
  @spec check_pin(integer()) :: auth_result()
  def check_pin(pin_id) do
    url = "#{@plex_api_base}/pins/#{pin_id}"

    headers = [
      {"Accept", "application/json"},
      {"X-Plex-Client-Identifier", @client_identifier}
    ]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        case body["authToken"] do
          nil ->
            :pending

          "" ->
            :pending

          token when is_binary(token) ->
            {:ok, %{auth_token: token}}
        end

      {:ok, %{status: 404}} ->
        {:error, "PIN expired or not found"}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to check Plex PIN: HTTP #{status}", body: inspect(body))
        {:error, "Failed to check PIN: HTTP #{status}"}

      {:error, exception} ->
        Logger.error("Failed to check Plex PIN: #{Exception.message(exception)}")
        {:error, "Network error: #{Exception.message(exception)}"}
    end
  end

  @doc """
  Generates the Plex authorization URL for the user to visit.

  The user should be directed to this URL (usually in a popup window)
  to log in and authorize the application.
  """
  @spec get_auth_url(String.t()) :: String.t()
  def get_auth_url(code) do
    params =
      URI.encode_query(%{
        "clientID" => @client_identifier,
        "code" => code,
        "context[device][product]" => @product_name
      })

    "#{@plex_auth_base}?#{params}"
  end

  @doc """
  Lists the user's Plex servers using their auth token.

  Returns a list of servers with their connection information.
  Servers are filtered to only include those that provide "server" capability.

  Options:
    * `:plex_tv_base` - override the plex.tv base URL (tests only)
  """
  @spec list_servers(String.t(), keyword()) :: {:ok, [server()]} | {:error, term()}
  def list_servers(auth_token, opts \\ []) do
    base = Keyword.get(opts, :plex_tv_base, @plex_api_base)
    url = "#{base}/resources"

    headers = [
      {"Accept", "application/json"},
      {"X-Plex-Token", auth_token},
      {"X-Plex-Client-Identifier", @client_identifier}
    ]

    params = [includeHttps: 1, includeRelay: 1]

    case Req.get(url, headers: headers, params: params) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        servers =
          body
          |> Enum.filter(&server_resource?/1)
          |> Enum.map(&parse_server/1)

        {:ok, servers}

      {:ok, %{status: 401}} ->
        {:error, "Invalid or expired auth token"}

      {:ok, %{status: status, body: body}} ->
        Logger.error("Failed to list Plex servers: HTTP #{status}", body: inspect(body))
        {:error, "Failed to list servers: HTTP #{status}"}

      {:error, exception} ->
        Logger.error("Failed to list Plex servers: #{Exception.message(exception)}")
        {:error, "Network error: #{Exception.message(exception)}"}
    end
  end

  @doc """
  Returns the best connection URL for a server.

  Preference order:
  1. Local HTTPS connections
  2. Local HTTP connections
  3. Remote HTTPS connections
  4. Remote HTTP connections
  5. Relay connections (last resort)
  """
  @spec best_connection_url([connection()]) :: String.t() | nil
  def best_connection_url(connections) when is_list(connections) do
    connections
    |> Enum.sort_by(&connection_priority/1)
    |> List.first()
    |> case do
      nil -> nil
      conn -> conn.uri
    end
  end

  def best_connection_url(_), do: nil

  @doc """
  Returns the client identifier used for OAuth requests.
  """
  @spec client_identifier() :: String.t()
  def client_identifier, do: @client_identifier

  # Private functions

  defp server_resource?(%{"provides" => provides}) when is_binary(provides) do
    provides
    |> String.split(",")
    |> Enum.any?(&(&1 == "server"))
  end

  defp server_resource?(_), do: false

  @doc """
  Parses one `/api/v2/resources` entry.

  Public because rediscovery re-parses the same payload when a server's
  addresses change.
  """
  def parse_server(resource) do
    %{
      name: resource["name"],
      client_identifier: resource["clientIdentifier"],
      machine_identifier: resource["clientIdentifier"],
      access_token: resource["accessToken"],
      provides: resource["provides"],
      owned: resource["owned"] == true,
      presence: resource["presence"] == true,
      connections: parse_connections(resource["connections"] || [])
    }
  end

  defp parse_connections(connections) when is_list(connections) do
    Enum.map(connections, fn conn ->
      %{
        uri: conn["uri"],
        protocol: conn["protocol"],
        address: conn["address"],
        port: conn["port"],
        local: conn["local"] == true,
        relay: conn["relay"] == true
      }
    end)
  end

  defp parse_connections(_), do: []

  # Lower number = higher priority
  defp connection_priority(%{relay: true}), do: 5
  defp connection_priority(%{local: true, protocol: "https"}), do: 1
  defp connection_priority(%{local: true}), do: 2
  defp connection_priority(%{protocol: "https"}), do: 3
  defp connection_priority(_), do: 4
end
