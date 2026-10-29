defmodule Mydia.Indexers.Cardigann.TemplateContext do
  @moduledoc false

  alias Mydia.Indexers.Cardigann.Charset
  alias Mydia.Indexers.Cardigann.Links
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannFilters
  alias Mydia.Indexers.CardigannTemplate

  @doc """
  Renders one search input value into the site's charset (query strings and form
  bodies carry its bytes; Req percent-encodes them later). A template that fails
  to render yields `:render_failed` so the caller omits the input instead of
  sending its source.
  """
  @spec render_input(term(), map(), String.t() | nil) :: term()
  def render_input(v, context, encoding) when is_binary(v) do
    # "$raw:" is an explicit marker with the same behaviour as a plain template.
    template = String.replace_prefix(v, "$raw:", "")

    case CardigannTemplate.render(template, context, url_encode: false) do
      {:ok, rendered} -> Charset.encode(rendered, encoding)
      {:error, _} -> :render_failed
    end
  end

  def render_input(v, _context, _encoding), do: v

  @spec build(Parsed.t(), keyword()) :: map()
  def build(%Parsed{} = definition, opts) do
    query =
      opts
      |> Keyword.get(:query, "")
      |> CardigannFilters.apply_keywords_filters(definition)

    %{
      keywords: query,
      config: config(definition, opts),
      query: %{
        series: query,
        season: Keyword.get(opts, :season),
        episode: Keyword.get(opts, :episode),
        imdb_id: Keyword.get(opts, :imdb_id),
        tmdb_id: Keyword.get(opts, :tmdb_id),
        tvdb_id: Keyword.get(opts, :tvdb_id)
      },
      categories: Keyword.get(opts, :categories, []),
      settings: definition.settings
    }
  end

  # Prowlarr's `.Config.sitelink` (CardigannBase.GetBaseTemplateVariables): the
  # site being searched, with the trailing slash definition links carry. A
  # setting of the same name overrides it there too.
  defp config(definition, opts) do
    config = Keyword.get(opts, :config) || %{}

    case Keyword.get(opts, :base_url) || List.first(Links.current(definition)) do
      url when is_binary(url) and url != "" ->
        Map.put_new(config, "sitelink", String.trim_trailing(url, "/") <> "/")

      _ ->
        config
    end
  end
end
