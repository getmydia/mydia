defmodule Mydia.Collections.Presets do
  @moduledoc """
  The preset collection catalog: common smart collections offered as one-click
  additions.

  Pure data. No database access and no configuration, so the catalog is
  reviewable as a diff and testable without a repo. `test/mydia/collections/presets_test.exs`
  walks every entry, validating and executing its rules, because a bad entry is
  otherwise invisible until a user clicks it.

  Adding a preset produces an independent collection. Editing this catalog later
  does not change collections that were already created from it.
  """

  alias Mydia.Collections.Preset

  @groups ["Decades", "Genres", "Highlights", "Series", "Language"]

  @presets [
    # Decades
    %Preset{
      key: "decade_1980s",
      name: "1980s",
      description: "Everything released between 1980 and 1989.",
      icon: "hero-film",
      group: "Decades",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "year", "operator" => "between", "value" => [1980, 1989]}
        ],
        "sort" => %{"field" => "year", "direction" => "desc"}
      }
    },
    %Preset{
      key: "decade_1990s",
      name: "1990s",
      description: "Everything released between 1990 and 1999.",
      icon: "hero-film",
      group: "Decades",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "year", "operator" => "between", "value" => [1990, 1999]}
        ],
        "sort" => %{"field" => "year", "direction" => "desc"}
      }
    },
    %Preset{
      key: "decade_2000s",
      name: "2000s",
      description: "Everything released between 2000 and 2009.",
      icon: "hero-film",
      group: "Decades",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "year", "operator" => "between", "value" => [2000, 2009]}
        ],
        "sort" => %{"field" => "year", "direction" => "desc"}
      }
    },
    %Preset{
      key: "decade_2010s",
      name: "2010s",
      description: "Everything released between 2010 and 2019.",
      icon: "hero-film",
      group: "Decades",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "year", "operator" => "between", "value" => [2010, 2019]}
        ],
        "sort" => %{"field" => "year", "direction" => "desc"}
      }
    },
    %Preset{
      key: "decade_2020s",
      name: "2020s",
      description: "Everything released from 2020 onward.",
      icon: "hero-film",
      group: "Decades",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "year", "operator" => "between", "value" => [2020, 2029]}
        ],
        "sort" => %{"field" => "year", "direction" => "desc"}
      }
    },

    # Genres
    %Preset{
      key: "genre_action",
      name: "Action",
      description: "Action titles from across your library.",
      icon: "hero-bolt",
      group: "Genres",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{
            "field" => "metadata.genres",
            "operator" => "contains_any",
            "value" => ["Action", "Action & Adventure"]
          }
        ],
        "sort" => %{"field" => "year", "direction" => "desc"}
      }
    },
    %Preset{
      key: "genre_comedy",
      name: "Comedy",
      description: "Comedies from across your library.",
      icon: "hero-face-smile",
      group: "Genres",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "metadata.genres", "operator" => "contains_any", "value" => ["Comedy"]}
        ],
        "sort" => %{"field" => "year", "direction" => "desc"}
      }
    },
    %Preset{
      key: "genre_horror",
      name: "Horror",
      description: "Horror titles from across your library.",
      icon: "hero-fire",
      group: "Genres",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "metadata.genres", "operator" => "contains_any", "value" => ["Horror"]}
        ],
        "sort" => %{"field" => "year", "direction" => "desc"}
      }
    },
    %Preset{
      key: "genre_science_fiction",
      name: "Science Fiction",
      description: "Science fiction and fantasy from across your library.",
      icon: "hero-rocket-launch",
      group: "Genres",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{
            "field" => "metadata.genres",
            "operator" => "contains_any",
            # TMDB names this genre differently for movies and for series.
            "value" => ["Science Fiction", "Sci-Fi & Fantasy"]
          }
        ],
        "sort" => %{"field" => "year", "direction" => "desc"}
      }
    },
    %Preset{
      key: "genre_documentary",
      name: "Documentary",
      description: "Documentaries from across your library.",
      icon: "hero-book-open",
      group: "Genres",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{
            "field" => "metadata.genres",
            "operator" => "contains_any",
            "value" => ["Documentary"]
          }
        ],
        "sort" => %{"field" => "year", "direction" => "desc"}
      }
    },
    %Preset{
      key: "genre_animation",
      name: "Animation",
      description: "Animated titles from across your library.",
      icon: "hero-sparkles",
      group: "Genres",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "metadata.genres", "operator" => "contains_any", "value" => ["Animation"]}
        ],
        "sort" => %{"field" => "year", "direction" => "desc"}
      }
    },

    # Highlights
    %Preset{
      key: "highly_rated",
      name: "Highly Rated",
      description: "Rated 8.0 or better.",
      icon: "hero-star",
      group: "Highlights",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "metadata.vote_average", "operator" => "gte", "value" => 8.0}
        ],
        "sort" => %{"field" => "rating", "direction" => "desc"}
      }
    },
    %Preset{
      key: "recently_added",
      name: "Recently Added",
      description: "Added to your library in the last 30 days.",
      icon: "hero-sparkles",
      group: "Highlights",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "inserted_at", "operator" => "within_last", "value" => 30}
        ],
        "sort" => %{"field" => "added_date", "direction" => "desc"}
      }
    },

    # Series
    %Preset{
      key: "ongoing_series",
      name: "Ongoing Series",
      description: "Series that are still releasing new episodes.",
      icon: "hero-tv",
      group: "Series",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "type", "operator" => "eq", "value" => "tv_show"},
          %{"field" => "metadata.status", "operator" => "eq", "value" => "Returning Series"}
        ],
        "sort" => %{"field" => "title", "direction" => "asc"}
      }
    },
    %Preset{
      key: "completed_series",
      name: "Completed Series",
      description: "Series that have finished their run.",
      icon: "hero-tv",
      group: "Series",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "type", "operator" => "eq", "value" => "tv_show"},
          %{"field" => "metadata.status", "operator" => "eq", "value" => "Ended"}
        ],
        "sort" => %{"field" => "title", "direction" => "asc"}
      }
    },

    # Language
    %Preset{
      key: "foreign_language",
      name: "Foreign Language",
      description: "Titles whose original language is not English.",
      icon: "hero-globe-alt",
      group: "Language",
      rules: %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "metadata.original_language", "operator" => "not_in", "value" => ["en"]}
        ],
        "sort" => %{"field" => "year", "direction" => "desc"}
      }
    }
  ]

  @doc """
  Returns every preset in display order.
  """
  @spec list() :: [Preset.t()]
  def list, do: @presets

  @doc """
  Returns the preset with the given key, or nil.
  """
  @spec get(String.t()) :: Preset.t() | nil
  def get(key) when is_binary(key) do
    Enum.find(@presets, &(&1.key == key))
  end

  def get(_), do: nil

  @doc """
  Returns the group names in the order the gallery should render them.
  """
  @spec groups() :: [String.t()]
  def groups, do: @groups
end
