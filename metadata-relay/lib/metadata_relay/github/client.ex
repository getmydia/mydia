defmodule MetadataRelay.GitHub.Client do
  @moduledoc """
  Authenticated GitHub REST calls made on behalf of the signed-in maintainer.

  The token is always supplied by the caller. The relay holds no long-lived
  GitHub credential of its own.
  """

  alias MetadataRelay.Feedback.IssueDraft

  @config_key MetadataRelay.GitHub
  @api_url "https://api.github.com"
  @default_repo "getmydia/mydia"

  @doc "Target repository in `owner/repo` form."
  def repo do
    :metadata_relay
    |> Application.get_env(@config_key, [])
    |> Keyword.get(:repo)
    |> case do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> @default_repo
          trimmed -> trimmed
        end

      _ ->
        @default_repo
    end
  end

  @doc """
  Creates an issue from a draft or an equivalent map of `:title`, `:body` and
  `:labels`.
  """
  def create_issue(%IssueDraft{} = draft, token) do
    create_issue(%{title: draft.title, body: draft.body, labels: draft.labels}, token)
  end

  def create_issue(%{title: title, body: body} = attrs, token) when is_binary(token) do
    payload = %{
      title: title,
      body: body,
      labels: Map.get(attrs, :labels, [])
    }

    request =
      req_new(
        url: @api_url <> "/repos/" <> repo() <> "/issues",
        method: :post,
        headers: [
          {"accept", "application/vnd.github+json"},
          {"authorization", "Bearer " <> token},
          {"x-github-api-version", "2022-11-28"}
        ],
        json: payload
      )

    case Req.request(request) do
      {:ok, %{status: 201, body: %{"number" => number, "html_url" => html_url}}} ->
        {:ok, %{number: number, html_url: html_url}}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, {:unauthorized, "GitHub rejected your sign-in. Sign in again and retry."}}

      {:ok, %{status: 404}} ->
        {:error,
         {:not_found, "Repository #{repo()} not found, or your account lacks Issues access."}}

      {:ok, %{status: 422, body: body}} ->
        {:error, {:unprocessable, message(body, "GitHub rejected the issue.")}}

      {:ok, %{status: _status}} ->
        {:error, {:server_error, "GitHub is unreachable. Your draft is preserved, try again."}}

      {:error, _reason} ->
        {:error, {:transport, "GitHub is unreachable. Your draft is preserved, try again."}}
    end
  end

  defp message(%{"message" => message}, _default) when is_binary(message), do: message
  defp message(_body, default), do: default

  defp req_new(opts) do
    adapter = Application.get_env(:metadata_relay, :github_http_adapter)
    opts = if adapter, do: Keyword.put(opts, :adapter, adapter), else: opts

    Req.new(opts)
  end
end
