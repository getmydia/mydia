defmodule Mydia.Collections.SectionPresets do
  @moduledoc """
  Ready-made sidebar sections offered when a user adds one.

  The catalog is deliberately limited to what `Mydia.Collections.SmartRules`
  can express. Its `@valid_fields` has no quality field, so there is no "4K"
  preset, and `Collection.changeset/2` requires at least one condition, so
  there is no sort-only "Recently Added" preset either. Adding one of those
  means extending the rule vocabulary first.
  """

  @type preset :: %{
          key: String.t(),
          name: String.t(),
          icon: String.t(),
          description: String.t(),
          rules: map(),
          exclusive: boolean()
        }

  @presets [
    %{
      key: "anime",
      name: "Anime",
      icon: "hero-sparkles",
      description: "Japanese animation, movies and series, out of Movies and TV.",
      rules: %{
        "conditions" => [
          %{
            "field" => "category",
            "operator" => "in",
            "value" => ["anime_movie", "anime_series"]
          }
        ]
      },
      exclusive: true
    },
    %{
      key: "cartoons",
      name: "Cartoons",
      icon: "hero-face-smile",
      description: "Western animation, movies and series, out of Movies and TV.",
      rules: %{
        "conditions" => [
          %{
            "field" => "category",
            "operator" => "in",
            "value" => ["cartoon_movie", "cartoon_series"]
          }
        ]
      },
      exclusive: true
    },
    %{
      key: "documentaries",
      name: "Documentaries",
      icon: "hero-globe-alt",
      description: "Anything tagged with the Documentary genre. Stays in Movies and TV.",
      rules: %{
        "conditions" => [
          %{"field" => "metadata.genres", "operator" => "contains", "value" => "Documentary"}
        ]
      },
      exclusive: false
    }
  ]

  @doc """
  Returns every preset in display order.
  """
  @spec all() :: [preset()]
  def all, do: @presets

  @doc """
  Returns the preset with the given key, or nil.
  """
  @spec get(String.t()) :: preset() | nil
  def get(key) when is_binary(key), do: Enum.find(@presets, &(&1.key == key))
  def get(_), do: nil
end
