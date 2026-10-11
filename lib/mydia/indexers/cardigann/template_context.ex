defmodule Mydia.Indexers.Cardigann.TemplateContext do
  @moduledoc false

  alias Mydia.Indexers.Cardigann.Charset
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannFilters

  @spec build(Parsed.t(), keyword()) :: map()
  def build(%Parsed{} = definition, opts) do
    query =
      opts
      |> Keyword.get(:query, "")
      |> CardigannFilters.apply_keywords_filters(definition)

    %{
      # Encoded last so the site gets the charset's bytes once the template
      # percent-encodes them. `query.series` below stays UTF-8 text.
      keywords: Charset.encode(query, definition.encoding),
      config: Keyword.get(opts, :config, %{}),
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
end
