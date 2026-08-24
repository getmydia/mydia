defmodule MetadataRelay.TMDB.Client do
  @moduledoc """
  HTTP client for TMDB API v3.

  This module provides a thin wrapper around the TMDB API using Req.
  It handles authentication and forwards requests to TMDB, returning
  the raw API responses.

  ## Testing

  For testing, you can configure a custom HTTP adapter via application config:

      config :metadata_relay, :tmdb_http_adapter, fn request ->
        {request, Req.Response.new(status: 200, body: %{})}
      end

  """

  @base_url "https://api.themoviedb.org/3"

  alias MetadataRelay.ReqAdapter

  @doc """
  Creates a new Req client configured for TMDB API requests.

  Requires TMDB_API_KEY environment variable to be set.
  """
  def new do
    base_opts = [
      base_url: @base_url,
      headers: [
        {"accept", "application/json"},
        {"content-type", "application/json"}
      ]
    ]

    base_opts
    |> Req.new()
    |> ReqAdapter.attach(Application.get_env(:metadata_relay, :tmdb_http_adapter))
  end

  @doc """
  GET request to TMDB API.

  Returns `{:ok, response}` on success or `{:error, reason}` on failure.
  """
  def get(path, opts \\ []) do
    client = new()

    # `api_key` is combined with the caller's params here, at request time,
    # rather than baked into the client's own `:params` option in `new/0`.
    # The caller's params are a plain string-keyed map (the relay never
    # atomizes them -- see Router.extract_query_params/1), and Req's own
    # option-merge logic special-cases `:params` by calling
    # `Keyword.merge(old, new)` whenever *both* the client and the request
    # already declare one -- which raises unless `new` is a genuine
    # (atom-keyed) keyword list. Keeping the client's base `:params` empty
    # sidesteps that merge entirely: this call is then the only place
    # `:params` is set, so Req just uses it as given.
    # A caller-supplied `api_key` is dropped rather than forwarded: params now
    # pass through verbatim, so without this a request carrying its own
    # `?api_key=` would emit the key twice and TMDB would resolve the
    # duplicate to whichever it prefers -- turning a caller-controlled value
    # into the credential the relay authenticates with. The relay's key is the
    # only one that may reach TMDB.
    params =
      opts
      |> Keyword.get(:params, %{})
      |> Enum.reject(fn {key, _value} -> to_string(key) == "api_key" end)

    request_params = [{"api_key", get_api_key()} | params]

    case Req.get(client, url: path, params: request_params) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_api_key do
    case System.get_env("TMDB_API_KEY") do
      nil ->
        raise RuntimeError, """
        TMDB_API_KEY environment variable is not set.
        Please set it to your TMDB API key.
        """

      key ->
        key
    end
  end
end
