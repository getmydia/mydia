defmodule Mydia.Downloads.Client.HTTP do
  @moduledoc """
  Shared HTTP client utilities for download client adapters.

  This module provides common HTTP request functionality using the Req library,
  with support for authentication, error handling, and timeout configuration.

  ## Usage

      # Create a base request
      req = HTTP.new_request(config)

      # Make a GET request
      {:ok, response} = HTTP.get(req, "/api/v2/torrents/info")

      # Make a POST request
      {:ok, response} = HTTP.post(req, "/api/v2/torrents/add", body: form_data)

      # Make a request and automatically handle errors
      case HTTP.get(req, "/api/v2/app/version") do
        {:ok, %{status: 200, body: body}} -> {:ok, body}
        {:ok, response} -> {:error, Error.api_error("Unexpected status", %{response: response})}
        {:error, error} -> {:error, error}
      end

  ## Configuration

  The HTTP client is configured based on the download client config:

      config = %{
        host: "localhost",
        port: 8080,
        username: "admin",
        password: "adminpass",
        use_ssl: false,
        options: %{
          timeout: 30_000,  # request timeout in ms
          connect_timeout: 5_000  # connection timeout in ms
        }
      }

  ## Authentication

  The module automatically handles various authentication methods:

    * Basic authentication (username/password in config)
    * Cookie-based authentication (for clients that require login)
    * Token-based authentication (via headers in options)

  ## Error Handling

  All HTTP errors are automatically converted to `Mydia.Downloads.Client.Error`
  structs for consistent error handling across adapters.
  """

  alias Mydia.Downloads.Client.Error

  @type request :: Req.Request.t()
  @type response :: Req.Response.t()
  @type config :: map()

  @default_timeout 30_000
  @default_connect_timeout 5_000

  @doc """
  Creates a new Req request struct configured for the download client.

  ## Examples

      iex> config = %{host: "localhost", port: 8080, use_ssl: false}
      iex> req = HTTP.new_request(config)
      iex> req.url
      %URI{scheme: "http", host: "localhost", port: 8080}
  """
  @spec new_request(config()) :: request()
  def new_request(config) do
    base_url = build_base_url(config)
    timeout = get_in(config, [:options, :timeout]) || @default_timeout
    connect_timeout = get_in(config, [:options, :connect_timeout]) || @default_connect_timeout

    req =
      Req.new(
        base_url: base_url,
        receive_timeout: timeout,
        connect_options: [timeout: connect_timeout],
        retry: false
      )

    # Add authentication if credentials provided
    req =
      if config[:username] && config[:password] do
        Req.Request.put_header(req, "authorization", basic_auth_header(config))
      else
        req
      end

    req
  end

  @doc """
  Makes a GET request.

  ## Examples

      iex> req = HTTP.new_request(config)
      iex> HTTP.get(req, "/api/status")
      {:ok, %Req.Response{status: 200, body: %{...}}}
  """
  @spec get(request(), String.t(), keyword()) :: {:ok, response()} | {:error, Error.t()}
  def get(req, path, opts \\ []) do
    full_url = build_full_url(req, path)

    req
    |> Req.merge(url: full_url)
    |> Req.get(opts)
    |> handle_response()
  end

  @doc """
  Makes a POST request.

  ## Examples

      iex> req = HTTP.new_request(config)
      iex> HTTP.post(req, "/api/add", body: %{url: "magnet:..."})
      {:ok, %Req.Response{status: 200, body: %{...}}}
  """
  @spec post(request(), String.t(), keyword()) :: {:ok, response()} | {:error, Error.t()}
  def post(req, path, opts \\ []) do
    # Build full URL from base_url and path
    full_url = build_full_url(req, path)

    req
    |> Req.merge(url: full_url)
    |> Req.post(opts)
    |> handle_response()
  end

  defp build_full_url(req, path) do
    # Extract base_url from request options
    base_url = req.options[:base_url] || "http://localhost"
    # Ensure path starts with /
    path = if String.starts_with?(path, "/"), do: path, else: "/#{path}"
    # Combine base_url and path
    "#{base_url}#{path}"
  end

  @doc """
  Makes a PUT request.

  ## Examples

      iex> req = HTTP.new_request(config)
      iex> HTTP.put(req, "/api/torrents/pause", body: %{hash: "abc123"})
      {:ok, %Req.Response{status: 200, body: %{...}}}
  """
  @spec put(request(), String.t(), keyword()) :: {:ok, response()} | {:error, Error.t()}
  def put(req, path, opts \\ []) do
    full_url = build_full_url(req, path)

    req
    |> Req.merge(url: full_url)
    |> Req.put(opts)
    |> handle_response()
  end

  @doc """
  Makes a DELETE request.

  ## Examples

      iex> req = HTTP.new_request(config)
      iex> HTTP.delete(req, "/api/torrents/delete", body: %{hashes: "abc123"})
      {:ok, %Req.Response{status: 200, body: %{...}}}
  """
  @spec delete(request(), String.t(), keyword()) :: {:ok, response()} | {:error, Error.t()}
  def delete(req, path, opts \\ []) do
    full_url = build_full_url(req, path)

    req
    |> Req.merge(url: full_url)
    |> Req.delete(opts)
    |> handle_response()
  end

  @doc """
  Makes a request with custom method and options.

  ## Examples

      iex> req = HTTP.new_request(config)
      iex> HTTP.request(req, method: :patch, url: "/api/settings", json: %{key: "value"})
      {:ok, %Req.Response{status: 200, body: %{...}}}
  """
  @spec request(request(), keyword()) :: {:ok, response()} | {:error, Error.t()}
  def request(req, opts) do
    req
    |> Req.Request.merge_options(opts)
    |> Req.request()
    |> handle_response()
  end

  @doc """
  Builds a form-encoded body for POST requests.

  Many download clients expect form-encoded data rather than JSON.

  ## Examples

      iex> HTTP.form_body(%{url: "magnet:...", category: "movies"})
      "url=magnet%3A...&category=movies"
  """
  @spec form_body(map()) :: String.t()
  def form_body(params) when is_map(params) do
    params
    |> Enum.map(fn {key, value} ->
      "#{URI.encode_www_form(to_string(key))}=#{URI.encode_www_form(to_string(value))}"
    end)
    |> Enum.join("&")
  end

  ## Private Functions

  defp build_base_url(config) do
    scheme = if config[:use_ssl], do: "https", else: "http"
    host = config[:host] || "localhost"
    port = config[:port]

    "#{scheme}://#{host}:#{port}"
  end

  defp basic_auth_header(config) do
    credentials = "#{config.username}:#{config.password}"
    encoded = Base.encode64(credentials)
    "Basic #{encoded}"
  end

  defp handle_response({:ok, %Req.Response{} = response}) do
    {:ok, response}
  end

  defp handle_response({:error, %Req.TransportError{} = error}) do
    {:error, Error.from_req_error(error)}
  end

  defp handle_response({:error, error}) do
    {:error, Error.unknown("Request failed: #{inspect(error)}")}
  end
end
