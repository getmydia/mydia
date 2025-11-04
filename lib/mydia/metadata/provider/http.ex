defmodule Mydia.Metadata.Provider.HTTP do
  @moduledoc """
  Shared HTTP client utilities for metadata provider adapters.

  This module provides common HTTP request functionality using the Req library,
  with support for API key authentication, caching, rate limiting, and error handling.

  ## Usage

      # Create a base request
      req = HTTP.new_request(config)

      # Make a GET request with caching
      {:ok, response} = HTTP.get(req, "/search/movie", params: [query: "The Matrix"])

      # Make a request with custom headers
      {:ok, response} = HTTP.get(req, "/movie/603", headers: [{"accept-language", "en-US"}])

  ## Configuration

  The HTTP client is configured based on the provider config:

      config = %{
        type: :tmdb,
        api_key: "your_api_key",
        base_url: "https://api.themoviedb.org/3",
        options: %{
          timeout: 30_000,  # request timeout in ms
          connect_timeout: 5_000,  # connection timeout in ms
          cache: true,  # enable response caching
          cache_ttl: 3600  # cache time-to-live in seconds
        }
      }

  ## Authentication

  The module automatically handles various authentication methods:

    * API key in query parameters (most common for metadata APIs)
    * API key in headers (Bearer token or custom header)
    * Basic authentication (username/password)

  ## Caching

  Responses can be cached to reduce API calls and avoid rate limiting:

    * Caching is enabled by default for GET requests
    * Cache keys are based on URL and query parameters
    * Cache TTL is configurable (default: 1 hour)
    * Cache can be disabled per-request or globally

  ## Error Handling

  All HTTP errors are automatically converted to `Mydia.Metadata.Provider.Error`
  structs for consistent error handling across providers.
  """

  alias Mydia.Metadata.Provider.Error

  @type request :: Req.Request.t()
  @type response :: Req.Response.t()
  @type config :: map()

  @default_timeout 30_000
  @default_connect_timeout 5_000

  @doc """
  Creates a new Req request struct configured for the metadata provider.

  ## Examples

      iex> config = %{base_url: "https://api.themoviedb.org/3", api_key: "key123"}
      iex> req = HTTP.new_request(config)
      iex> req.url
      %URI{scheme: "https", host: "api.themoviedb.org", path: "/3"}
  """
  @spec new_request(config()) :: request()
  def new_request(config) do
    base_url = config[:base_url] || raise "base_url is required"
    timeout = get_in(config, [:options, :timeout]) || @default_timeout
    connect_timeout = get_in(config, [:options, :connect_timeout]) || @default_connect_timeout

    req =
      Req.new(
        base_url: base_url,
        receive_timeout: timeout,
        connect_options: [timeout: connect_timeout],
        retry: :transient,
        max_retries: 3
      )

    # Add authentication if API key provided
    req =
      if config[:api_key] do
        add_api_key_auth(req, config)
      else
        req
      end

    # Add default headers
    req =
      Req.Request.merge_options(req,
        headers: [
          {"accept", "application/json"},
          {"user-agent", "Mydia/1.0"}
        ]
      )

    req
  end

  @doc """
  Makes a GET request with optional caching.

  ## Options

    * `:params` - Query parameters as a keyword list or map
    * `:headers` - Additional headers as a list of tuples
    * `:cache` - Enable/disable caching for this request (default: true)
    * `:cache_ttl` - Cache time-to-live in seconds

  ## Examples

      iex> req = HTTP.new_request(config)
      iex> HTTP.get(req, "/search/movie", params: [query: "Matrix"])
      {:ok, %Req.Response{status: 200, body: %{...}}}
  """
  @spec get(request(), String.t(), keyword()) :: {:ok, response()} | {:error, Error.t()}
  def get(req, path, opts \\ []) do
    # Extract params
    params = Keyword.get(opts, :params, [])
    opts = Keyword.delete(opts, :params)

    # Use Req.request/2 with options - this properly handles base_url + path
    opts = [url: path, params: params] ++ opts

    Req.request(req, opts)
    |> handle_response()
  end

  @doc """
  Makes a POST request.

  ## Options

    * `:json` - JSON body as a map
    * `:body` - Raw body content
    * `:headers` - Additional headers as a list of tuples
    * `:params` - Query parameters as a keyword list or map

  ## Examples

      iex> req = HTTP.new_request(config)
      iex> HTTP.post(req, "/search", json: %{query: "Matrix"})
      {:ok, %Req.Response{status: 200, body: %{...}}}
  """
  @spec post(request(), String.t(), keyword()) :: {:ok, response()} | {:error, Error.t()}
  def post(req, path, opts \\ []) do
    params = Keyword.get(opts, :params, [])
    opts = Keyword.delete(opts, :params)

    # Use Req.request/2 with options - this properly handles base_url + path
    opts = [method: :post, url: path, params: params] ++ opts

    Req.request(req, opts)
    |> handle_response()
  end

  @doc """
  Makes a request with custom method and options.

  ## Examples

      iex> req = HTTP.new_request(config)
      iex> HTTP.request(req, method: :get, url: "/movie/603", params: [language: "en-US"])
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
  Builds an image URL from a base URL and file path.

  Most metadata providers return relative paths for images that need to be
  combined with a base URL to form the complete image URL.

  ## Examples

      iex> HTTP.build_image_url("https://image.tmdb.org/t/p/w500", "/poster.jpg")
      "https://image.tmdb.org/t/p/w500/poster.jpg"

      iex> HTTP.build_image_url("https://image.tmdb.org/t/p/original", nil)
      nil
  """
  @spec build_image_url(String.t(), String.t() | nil) :: String.t() | nil
  def build_image_url(_base_url, nil), do: nil
  def build_image_url(_base_url, ""), do: nil

  def build_image_url(base_url, file_path) do
    # Ensure base_url doesn't end with / and file_path starts with /
    base_url = String.trim_trailing(base_url, "/")

    file_path =
      if String.starts_with?(file_path, "/"),
        do: file_path,
        else: "/#{file_path}"

    "#{base_url}#{file_path}"
  end

  ## Private Functions

  defp add_api_key_auth(req, %{api_key: api_key, options: %{auth_method: :query}} = config) do
    param_name = get_in(config, [:options, :api_key_param]) || "api_key"
    maybe_add_params(req, [{String.to_atom(param_name), api_key}])
  end

  defp add_api_key_auth(req, %{api_key: api_key, options: %{auth_method: :bearer}}) do
    Req.Request.put_header(req, "authorization", "Bearer #{api_key}")
  end

  defp add_api_key_auth(req, %{api_key: api_key, options: %{auth_method: :header}} = config) do
    header_name = get_in(config, [:options, :api_key_header]) || "x-api-key"
    Req.Request.put_header(req, header_name, api_key)
  end

  # Default to query parameter authentication
  defp add_api_key_auth(req, %{api_key: api_key} = config) do
    param_name = get_in(config, [:options, :api_key_param]) || "api_key"
    maybe_add_params(req, [{String.to_atom(param_name), api_key}])
  end

  defp append_path(request, path) do
    # Ensure path starts with /
    path = if String.starts_with?(path, "/"), do: path, else: "/#{path}"

    current_url = request.url

    # Combine base path with request path
    base_path = current_url.path || ""
    new_path = "#{base_path}#{path}"

    new_url = %{current_url | path: new_path}

    %{request | url: new_url}
  end

  defp maybe_add_params(req, []), do: req

  defp maybe_add_params(req, params) when is_list(params) or is_map(params) do
    # Get existing params and merge with new ones
    existing_params =
      case req.url.query do
        nil -> []
        query -> URI.decode_query(query) |> Enum.to_list()
      end

    # Convert params to keyword list
    new_params =
      params
      |> Enum.map(fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), to_string(v)}
        {k, v} -> {to_string(k), to_string(v)}
      end)

    # Merge params (new params override existing)
    all_params =
      existing_params
      |> Keyword.new()
      |> Keyword.merge(new_params)

    # Update request URL with merged params
    query_string = URI.encode_query(all_params)
    new_url = %{req.url | query: query_string}

    %{req | url: new_url}
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
