defmodule MydiaWeb.Schema.Resolvers.CollectionResolver do
  @moduledoc """
  Resolvers for collection-related GraphQL queries.
  """

  alias Mydia.Collections

  alias Mydia.Metadata.ImageUrl
  alias MydiaWeb.Schema.Resolvers.ItemBuilder

  @spec list_collections(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def list_collections(_parent, args, %{
        context: %{current_user: user, current_scope: scope}
      }) do
    first = Map.get(args, :first, 50)

    collections =
      Collections.list_collections(user)
      |> Enum.reject(& &1.is_system)
      |> Enum.take(first)
      |> Enum.map(&build_collection(&1, scope))

    {:ok, collections}
  end

  def list_collections(_parent, _args, _info), do: {:ok, []}

  @spec collection(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def collection(_parent, %{id: id}, %{context: %{current_user: user, current_scope: scope}}) do
    collection = Collections.get_collection!(user, id)
    {:ok, build_collection(collection, scope)}
  rescue
    Ecto.NoResultsError -> {:error, "Collection not found"}
  end

  def collection(_parent, _args, _info), do: {:error, "Not authenticated"}

  @spec collection_items(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def collection_items(_parent, %{collection_id: id} = args, %{
        context: %{current_user: user, current_scope: scope}
      }) do
    first = Map.get(args, :first, 50)
    collection = Collections.get_collection!(user, id)
    items = Collections.list_collection_items(scope, collection, limit: first)
    added_at = Mydia.Media.RecentlyAdded.added_at_map(ids: Enum.map(items, & &1.id))

    result =
      Enum.map(items, fn item ->
        ItemBuilder.recently_added_item(item, added_at: Map.get(added_at, item.id))
      end)

    {:ok, result}
  rescue
    Ecto.NoResultsError -> {:error, "Collection not found"}
  end

  def collection_items(_parent, _args, _info), do: {:ok, []}

  # Private helpers

  defp build_collection(collection, scope) do
    item_count = Collections.item_count(scope, collection)
    posters = Collections.poster_paths(scope, collection, 4)

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
