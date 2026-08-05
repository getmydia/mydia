defmodule MydiaWeb.Schema.Resolvers.CollectionResolver do
  @moduledoc """
  Resolvers for collection-related GraphQL queries.
  """

  alias Mydia.Collections

  alias Mydia.Metadata.ImageUrl
  alias MydiaWeb.Schema.Resolvers.ItemBuilder

  @spec list_collections(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def list_collections(_parent, args, %{context: %{current_user: user}}) do
    first = Map.get(args, :first, 50)

    collections =
      Collections.list_collections(user)
      |> Enum.reject(& &1.is_system)
      |> Enum.take(first)
      |> Enum.map(&build_collection/1)

    {:ok, collections}
  end

  def list_collections(_parent, _args, _info), do: {:ok, []}

  @spec collection(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def collection(_parent, %{id: id}, %{context: %{current_user: user}}) do
    collection = Collections.get_collection!(user, id)
    {:ok, build_collection(collection)}
  rescue
    Ecto.NoResultsError -> {:error, "Collection not found"}
  end

  def collection(_parent, _args, _info), do: {:error, "Not authenticated"}

  @spec collection_items(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def collection_items(_parent, %{collection_id: id} = args, %{context: %{current_user: user}}) do
    first = Map.get(args, :first, 50)
    collection = Collections.get_collection!(user, id)
    items = Collections.list_collection_items(collection, limit: first)

    result =
      items
      |> Enum.map(&ItemBuilder.recently_added_item/1)

    {:ok, result}
  rescue
    Ecto.NoResultsError -> {:error, "Collection not found"}
  end

  def collection_items(_parent, _args, _info), do: {:ok, []}

  # Private helpers

  defp build_collection(collection) do
    item_count = Collections.item_count(collection)
    posters = Collections.poster_paths(collection, 4)

    %{
      id: collection.id,
      name: collection.name,
      description: collection.description,
      type: collection.type,
      visibility: collection.visibility,
      item_count: item_count,
      poster_paths: Enum.map(posters, &ImageUrl.poster_url/1)
    }
  end
end
