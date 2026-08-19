defmodule MetadataRelay.GitHub.OAuth do
  @moduledoc """
  User-to-server authorization against the Mydia Relay GitHub App.

  The App's registered callback URL is used, so no `redirect_uri` is sent.
  GitHub Apps take their permissions from the App declaration, so no `scope`
  parameter is sent either.

  ## Testing

  Inject a Req adapter through application config:

      config :metadata_relay, :github_http_adapter, fn request ->
        {request, Req.Response.new(status: 200, body: %{})}
      end
  """

  @config_key MetadataRelay.GitHub

  @authorize_url "https://github.com/login/oauth/authorize"
  @token_url "https://github.com/login/oauth/access_token"
  @api_url "https://api.github.com"

  @doc "True when both App credentials are present."
  def configured?, do: not is_nil(client_id()) and not is_nil(client_secret())

  @doc "URL to send the browser to, carrying an anti-forgery state value."
  def authorize_url(state) when is_binary(state) do
    query = URI.encode_query(%{"client_id" => client_id(), "state" => state})
    @authorize_url <> "?" <> query
  end

  @doc "Trades an authorization code for a user access token."
  def exchange_code(code) when is_binary(code) do
    request =
      req_new(
        url: @token_url,
        method: :post,
        headers: [{"accept", "application/json"}],
        json: %{
          client_id: client_id(),
          client_secret: client_secret(),
          code: code
        }
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
        {:ok, token}

      {:ok, %{status: 200, body: %{"error" => error} = body}} ->
        {:error, {:oauth, Map.get(body, "error_description", error)}}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @doc "Looks up the authenticated user for a token."
  def fetch_user(token) when is_binary(token) do
    request =
      req_new(
        url: @api_url <> "/user",
        method: :get,
        headers: [
          {"accept", "application/vnd.github+json"},
          {"authorization", "Bearer " <> token},
          {"x-github-api-version", "2022-11-28"}
        ]
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: %{"login" => login}}} when is_binary(login) ->
        {:ok, %{login: login}}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @doc """
  Checks the authenticated user's membership of `org`.

  The endpoint is scoped to the caller's own membership, so it sees private
  membership without the App needing to read the org's member list.

  A pending invitation also answers 200, with `state` set to `"pending"`. Only
  `"active"` counts, otherwise merely inviting someone would hand them the
  dashboard.
  """
  def fetch_org_membership(token, org) when is_binary(token) and is_binary(org) do
    request =
      req_new(
        url: @api_url <> "/user/memberships/orgs/" <> URI.encode(org),
        method: :get,
        headers: [
          {"accept", "application/vnd.github+json"},
          {"authorization", "Bearer " <> token},
          {"x-github-api-version", "2022-11-28"}
        ]
      )

    case Req.request(request) do
      {:ok, %{status: 200, body: %{"state" => "active"}}} ->
        {:ok, :active}

      {:ok, %{status: 200, body: %{"state" => state}}} ->
        {:error, {:membership, state}}

      {:ok, %{status: 200}} ->
        {:error, {:membership, "unknown"}}

      {:ok, %{status: 404}} ->
        {:error, :not_a_member}

      # GitHub answers 403 for rate limiting as well as for refusal, so the
      # status alone cannot tell "you may not" from "not right now". Callers
      # sign a session out on a refusal, and doing that to a rate-limited
      # maintainer would be both wrong and confusing.
      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: 403} = response} ->
        if rate_limited?(response), do: {:error, :rate_limited}, else: {:error, {:http, 403}}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp rate_limited?(%{headers: headers}) do
    not is_nil(header(headers, "retry-after")) or header(headers, "x-ratelimit-remaining") == "0"
  end

  defp header(headers, name) when is_map(headers) do
    headers |> Map.get(name, []) |> List.wrap() |> List.first()
  end

  defp header(_headers, _name), do: nil

  defp req_new(opts) do
    adapter = Application.get_env(:metadata_relay, :github_http_adapter)
    opts = if adapter, do: Keyword.put(opts, :adapter, adapter), else: opts

    Req.new(opts)
  end

  defp client_id, do: config(:client_id)
  defp client_secret, do: config(:client_secret)

  defp config(key) do
    :metadata_relay
    |> Application.get_env(@config_key, [])
    |> Keyword.get(key)
    |> normalize()
  end

  defp normalize(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize(_), do: nil
end
