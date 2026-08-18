defmodule Mydia.Library.ReleaseParser.TargetContext do
  @moduledoc """
  Optional binding context for a parse: the user has already told us which
  TV show / movie this file belongs to, so the parser should lock title /
  year / type to those values and concentrate on season + episode +
  quality.

  Pure data — no `Mydia.Repo` or `Mydia.Media` runtime dependency. The
  caller is expected to load a fully-preloaded `%MediaItem{}` (with
  `:episodes` preloaded, and `:metadata` materialized as a
  `%MediaMetadata{}`) and build the context via `from_media_item/1`.
  """

  alias Mydia.Media.MediaItem
  alias Mydia.Metadata.Structs.MediaMetadata

  @enforce_keys [:type, :title]
  defstruct [
    :type,
    :title,
    :year,
    alt_titles: [],
    known_seasons: [],
    external_ids: %{tmdb: nil, tvdb: nil, imdb: nil}
  ]

  @type media_type :: :movie | :tv_show

  @type t :: %__MODULE__{
          type: media_type(),
          title: String.t(),
          alt_titles: [String.t()],
          year: integer() | nil,
          known_seasons: [integer()],
          external_ids: %{tmdb: integer() | nil, tvdb: integer() | nil, imdb: String.t() | nil}
        }

  @doc """
  Build a `%TargetContext{}` from a fully-loaded `%MediaItem{}`.

  Raises `ArgumentError` if `:episodes` is not preloaded — the caller is
  responsible for fetching the MediaItem with the right preloads. Failing
  loudly is preferable to silently producing an empty `known_seasons`
  list, which would defeat the purpose of binding.

  Alternative titles are sourced from `media_item.original_title` (when
  distinct from `title`) plus any `alternative_titles` carried in
  `media_item.metadata`.
  """
  @spec from_media_item(MediaItem.t()) :: t()
  def from_media_item(%MediaItem{episodes: %Ecto.Association.NotLoaded{}}) do
    raise ArgumentError,
          "TargetContext.from_media_item/1 requires :episodes to be preloaded. " <>
            "Use `Mydia.Repo.preload(media_item, :episodes)` or include `:episodes` in " <>
            "the original preload list."
  end

  def from_media_item(%MediaItem{} = item) do
    %__MODULE__{
      type: parse_type(item.type),
      title: item.title || "",
      year: item.year,
      alt_titles: build_alt_titles(item),
      known_seasons: extract_known_seasons(item.episodes),
      external_ids: %{tmdb: item.tmdb_id, tvdb: item.tvdb_id, imdb: item.imdb_id}
    }
  end

  defp parse_type("movie"), do: :movie
  defp parse_type("tv_show"), do: :tv_show
  defp parse_type(other), do: raise(ArgumentError, "unknown media_item.type: #{inspect(other)}")

  defp build_alt_titles(%MediaItem{title: title, original_title: original, metadata: metadata}) do
    metadata_titles =
      case metadata do
        %MediaMetadata{alternative_titles: titles} when is_list(titles) -> titles
        _ -> []
      end

    [original | metadata_titles]
    |> Enum.reject(fn t -> is_nil(t) or t == "" or t == title end)
    |> Enum.uniq()
  end

  defp extract_known_seasons(episodes) when is_list(episodes) do
    episodes
    |> Enum.map(& &1.season_number)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
