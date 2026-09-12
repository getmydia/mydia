defmodule Mydia.Indexers.NewznabEndpoint do
  @moduledoc false

  # Newznab services (including meta indexers such as NZBHydra2) are usually
  # served from `/api`, but a deployment prefix in the configured base URL and
  # the API path itself must join without duplicating or dropping slashes.

  @default_api_path "/api"

  @spec normalize_api_path(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_api_path(nil), do: {:ok, @default_api_path}

  def normalize_api_path(path) when is_binary(path) do
    path = String.trim(path)

    if path == "" do
      {:ok, @default_api_path}
    else
      cond do
        Regex.match?(~r/^[a-z][a-z0-9+.-]*:\/\//i, path) ->
          {:error, "must be a path, not a complete URL"}

        String.contains?(path, "?") ->
          {:error, "must not include a query string"}

        String.contains?(path, "#") ->
          {:error, "must not include a fragment"}

        true ->
          {:ok, "/" <> String.trim_leading(path, "/")}
      end
    end
  end

  def normalize_api_path(_path), do: {:error, "must be a path"}

  @spec join(String.t() | nil, term()) :: {:ok, String.t()} | {:error, String.t()}
  def join(base_path, api_path) do
    with {:ok, api_path} <- normalize_api_path(api_path) do
      prefix = base_path |> to_string() |> String.trim("/")
      suffix = String.trim_leading(api_path, "/")
      path = if prefix == "", do: "/#{suffix}", else: "/#{prefix}/#{suffix}"
      {:ok, path}
    end
  end
end
