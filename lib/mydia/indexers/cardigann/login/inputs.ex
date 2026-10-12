defmodule Mydia.Indexers.Cardigann.Login.Inputs do
  @moduledoc "Renders login paths, inputs and headers through the Cardigann template engine."

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.{CredentialScope, Links, TemplateContext}
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannTemplate

  @spec context(Parsed.t(), map()) :: map()
  def context(%Parsed{} = parsed, config),
    do: TemplateContext.build(parsed, config: config || %{}, query: "")

  @spec render(String.t() | nil, map()) :: {:ok, String.t()} | {:error, Error.t()}
  def render(nil, _context), do: {:ok, ""}

  def render(template, context) do
    case CardigannTemplate.render(template, context, url_encode: false) do
      {:ok, value} -> {:ok, value}
      {:error, _} -> {:error, Error.invalid_config("Could not render login template")}
    end
  end

  @spec render_map(%{String.t() => String.t()}, map()) :: {:ok, map()} | {:error, Error.t()}
  def render_map(inputs, context) do
    Enum.reduce_while(inputs, {:ok, %{}}, fn {key, template}, {:ok, acc} ->
      case render(template, context) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  @spec headers(Parsed.t(), map()) :: [{String.t(), String.t()}]
  def headers(%Parsed{login: login, search: search}, context) do
    login_headers = (login && Map.get(login, :headers)) || %{}

    source =
      if map_size(login_headers) > 0, do: login_headers, else: Map.get(search, :headers) || %{}

    for {name, values} <- source,
        value <- List.wrap(values),
        {:ok, rendered} <- [render(to_string(value), context)],
        do: {to_string(name), rendered}
  end

  # The login goes to the active link when it is one of the definition's own
  # origins, else to the first link. A legacy mirror never receives credentials.
  @spec base_url(Parsed.t(), CardigannDefinition.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def base_url(%Parsed{} = parsed, %CardigannDefinition{} = definition) do
    origins = CredentialScope.trusted_origins(parsed, definition.config || %{})
    active = definition.active_link && String.trim_trailing(definition.active_link, "/")

    cond do
      active && CredentialScope.allows?(origins, active) -> {:ok, active}
      link = List.first(Links.candidates(%{parsed | legacylinks: []})) -> {:ok, link}
      true -> {:error, Error.invalid_config("No site link configured")}
    end
  end

  @doc "Joins a site base URL and a definition path. Not for references found on a fetched page."
  @spec resolve(String.t(), String.t()) :: String.t()
  def resolve(base, path), do: base |> Kernel.<>("/") |> URI.merge(path) |> URI.to_string()

  @doc "Resolves a reference found on or returned by a fetched page (redirect, form action, image src)."
  @spec resolve_page(String.t(), String.t()) :: String.t()
  def resolve_page(page_url, ref), do: page_url |> URI.merge(ref) |> URI.to_string()
end
