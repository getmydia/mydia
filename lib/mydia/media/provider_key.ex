defmodule Mydia.Media.ProviderKey do
  @moduledoc """
  The `{media_type, provider, provider_id}` key that library- and request-status
  maps are keyed on.

  None of the three parts identifies a title on its own. TMDB and TVDB number
  their catalogues independently, so `671` names a different title on each. And
  since `20260905143012_scope_provider_id_uniqueness_by_type` scoped provider-id
  uniqueness by media type, a movie and a show may hold the same number on the
  same provider legitimately.

  Keying a status map on the bare id let all three collide, and whichever row
  was written last won: a pending TV request for id 550 rendered a movie with
  tmdb_id 550 as already "Requested", and a library movie with tmdb_id 550
  blocked a TV request for id 550 as a duplicate.

  Every producer and consumer of those maps builds its keys through this module,
  so the two sides cannot drift into disagreeing about the shape.
  """

  alias Mydia.Media.MediaItem

  @type provider :: :tmdb | :tvdb
  @type media_type :: :movie | :tv_show
  @type t :: {media_type(), provider(), integer()}

  @doc """
  Builds a key, or `nil` when there is no provider id to key on.

  Raises through `MediaItem.type_atom/1` on a type outside `movie`/`tv_show`,
  which is unreachable for a persisted row and means a corrupted one if it ever
  fires.
  """
  @spec new(String.t() | atom(), provider(), integer() | nil) :: t() | nil
  def new(_type, _provider, nil), do: nil

  def new(type, provider, id) when provider in [:tmdb, :tvdb] and is_integer(id) do
    {MediaItem.type_atom(type), provider, id}
  end

  @doc """
  Builds the key for a card item, or `nil` when the item cannot be keyed.

  Card items are `Mydia.Metadata.Structs.SearchResult`s and the plain maps the
  recommendation and franchise rails build, which carry `:provider_id` plus the
  `:media_type` and `:provider` it belongs to.

  Returns `nil` rather than guessing when `:media_type` is missing. A guess
  would be a coin flip that renders a show's status on a movie's card, which is
  the bug this key exists to prevent; `nil` reads as "no status known", which is
  what the callers already render for an item that is not in the library.

  A `:provider_id` that is not a number also yields `nil`. `Add.parse_provider_id/1`
  raises on one, and a malformed id from a provider response should not take a
  whole rail down.
  """
  @spec from_card(map()) :: t() | nil
  def from_card(item) do
    with type when type in [:movie, :tv_show] <- card_media_type(item),
         id when is_integer(id) <- card_provider_id(item) do
      {type, card_provider(item), id}
    else
      _ -> nil
    end
  end

  defp card_media_type(item) do
    case Map.get(item, :media_type) do
      type when type in [:movie, "movie"] -> :movie
      type when type in [:tv_show, "tv_show"] -> :tv_show
      _ -> nil
    end
  end

  # Anything that is not explicitly TVDB is a TMDB id. TMDB is the default
  # provider throughout the add and discover flows, and only the TVDB-sourced
  # show paths set `:provider` at all.
  defp card_provider(item) do
    if Map.get(item, :provider) == :tvdb, do: :tvdb, else: :tmdb
  end

  defp card_provider_id(item) do
    case Map.get(item, :provider_id) do
      nil -> nil
      id when is_integer(id) -> id
      id when is_binary(id) -> parse_binary_id(id)
      _ -> nil
    end
  end

  defp parse_binary_id(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end
end
