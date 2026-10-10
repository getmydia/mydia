defmodule Mydia.Media.Favorites do
  @moduledoc """
  Favorite checks and toggling for media items, delegated to the Collections context.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Accounts.Scope
  alias Mydia.Media.{MediaItem, Restrictions}

  ## Favorites (delegated to Collections context)
  ##
  ## These functions now delegate to the Collections context which uses the
  ## unified collection system. The user_favorites table is deprecated.

  @doc """
  Checks if a media item is favorited by a user.

  Delegates to Collections.is_favorite?/3.

  ## Examples

      iex> is_favorite?(scope, user_id, media_item_id)
      true

      iex> is_favorite?(scope, user_id, non_favorited_media_item_id)
      false

  """
  @spec is_favorite?(Scope.t(), binary(), binary()) :: boolean()
  def is_favorite?(%Scope{} = scope, user_id, media_item_id) do
    visible? =
      MediaItem
      |> Restrictions.apply(scope)
      |> where([m], m.id == ^media_item_id)
      |> Repo.exists?()

    if visible? do
      # `user_id` is the favorites owner, which may not be `scope.user` (a
      # caller could in principle check a different user's status), so the
      # owner's own restrictions govern the Collections-level check rather
      # than reusing `scope` as-is.
      user = Mydia.Accounts.get_user!(user_id)
      Mydia.Collections.is_favorite?(Scope.for_user(user), media_item_id)
    else
      false
    end
  end

  @doc """
  Toggles favorite status for a media item.

  Delegates to Collections.toggle_favorite/2.

  Returns {:ok, :added} or {:ok, :removed} on success.

  ## Examples

      iex> toggle_favorite(user_id, media_item_id)
      {:ok, :added}

      iex> toggle_favorite(user_id, media_item_id)
      {:ok, :removed}

  """
  @spec toggle_favorite(binary(), binary()) :: {:ok, :added | :removed} | {:error, term()}
  def toggle_favorite(user_id, media_item_id) do
    user = Mydia.Accounts.get_user!(user_id)
    Mydia.Collections.toggle_favorite(user, media_item_id)
  end

  @doc """
  Lists all favorite media items for a user.

  Delegates to Collections context and returns the media items from
  the user's Favorites collection.

  ## Options
    - `:preload` - List of associations to preload on media_items

  ## Examples

      iex> list_user_favorites(user_id)
      [%MediaItem{}, ...]

      iex> list_user_favorites(user_id, preload: [:media_files])
      [%MediaItem{media_files: [...]}, ...]

  """
  @spec list_user_favorites(Scope.t(), binary(), keyword()) :: [MediaItem.t()]
  def list_user_favorites(%Scope{} = scope, user_id, opts \\ []) do
    user = Mydia.Accounts.get_user!(user_id)

    case Mydia.Collections.get_or_create_favorites(user) do
      {:ok, favorites} ->
        Mydia.Collections.list_collection_items(scope, favorites, opts)

      {:error, _} ->
        []
    end
  end
end
