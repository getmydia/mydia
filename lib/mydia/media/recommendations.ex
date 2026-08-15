defmodule Mydia.Media.Recommendations do
  @moduledoc """
  Resolves TMDB's recommendations for a title.

  Serves two surfaces with different inputs: the library detail page, which has a
  `MediaItem` row, and the Discover modal, which has only a TMDB id and a type
  because the title is not in the library.

  Every outcome that is not a non-empty list collapses to `:none` — no tmdb_id,
  an unsupported media type, an empty result, a relay error. The rail is meant to
  be silently absent whenever the lookup does not work out, so the caller has
  exactly one thing to check.

  Results are deliberately **not** joined against the library here. That join
  needs `MydiaWeb.Live.Helpers.MediaAddHelpers`, and a context under `Mydia.*`
  must not depend on the web layer, so the LiveViews enrich what they render.
  """

  require Logger

  alias Mydia.Media.MediaItem
  alias Mydia.Metadata
  alias Mydia.Metadata.Structs.SearchResult

  @media_types %{"movie" => :movie, "tv_show" => :tv_show}

  @doc """
  Returns recommendations for a library item, or `:none`.

  `config` is the relay configuration; it defaults to
  `Metadata.default_relay_config/0` and exists so tests can inject a stub without
  touching global environment.
  """
  @spec for_media_item(MediaItem.t(), map() | nil) :: {:ok, [SearchResult.t()]} | :none
  def for_media_item(media_item, config \\ nil)

  def for_media_item(%MediaItem{type: type, tmdb_id: tmdb_id}, config)
      when is_integer(tmdb_id) and is_map_key(@media_types, type) do
    for_tmdb_id(tmdb_id, Map.fetch!(@media_types, type), config)
  end

  def for_media_item(_media_item, _config), do: :none

  @doc """
  Returns recommendations for a bare TMDB id, or `:none`.

  This is the entry point for the Discover modal, where the title has no
  `MediaItem` row because it is not in the library.
  """
  @spec for_tmdb_id(integer() | String.t() | nil, :movie | :tv_show, map() | nil) ::
          {:ok, [SearchResult.t()]} | :none
  def for_tmdb_id(tmdb_id, media_type, config \\ nil)

  def for_tmdb_id(nil, _media_type, _config), do: :none

  def for_tmdb_id(tmdb_id, media_type, config) when media_type in [:movie, :tv_show] do
    config = config || Metadata.default_relay_config()

    case Metadata.fetch_recommendations_cached(config, to_string(tmdb_id), media_type: media_type) do
      {:ok, []} ->
        :none

      {:ok, results} when is_list(results) ->
        {:ok, results}

      {:error, reason} ->
        Logger.warning(
          "Recommendations lookup failed for tmdb #{tmdb_id} (#{media_type}): #{inspect(reason)}"
        )

        :none
    end
  end

  def for_tmdb_id(_tmdb_id, _media_type, _config), do: :none
end
