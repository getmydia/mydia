defmodule Mydia.Accounts.DiscoverIgnores do
  @moduledoc """
  Each user's Discover ignore list (#1379): titles they never want to see while
  browsing Discover.

  Keys are `{media_type, ref}`. TMDB numbers movies and TV separately, so the
  ref alone would let a movie ignore hide an unrelated show.
  """

  import Ecto.Query, warn: false

  alias Mydia.Accounts.{IgnoredDiscoverTitle, User}
  alias Mydia.Metadata.Ref
  alias Mydia.Repo

  @type key :: {:movie | :tv_show, Ref.t()}

  @doc """
  Adds a title to the user's ignore list.

  Idempotent: ignoring an already ignored title returns `:ok`, so a double
  click or a second tab is harmless.
  """
  @spec ignore(User.t(), Ref.t(), :movie | :tv_show) :: :ok | {:error, Ecto.Changeset.t()}
  def ignore(%User{id: user_id}, {provider, provider_id}, media_type) do
    %IgnoredDiscoverTitle{user_id: user_id}
    |> IgnoredDiscoverTitle.changeset(%{
      media_type: to_string(media_type),
      provider: to_string(provider),
      provider_id: provider_id
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:user_id, :media_type, :provider, :provider_id]
    )
    |> case do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Removes a title from the user's ignore list. Idempotent."
  @spec unignore(User.t(), Ref.t(), :movie | :tv_show) :: :ok
  def unignore(%User{id: user_id}, {provider, provider_id}, media_type) do
    media_type = to_string(media_type)
    provider = to_string(provider)

    from(i in IgnoredDiscoverTitle,
      where:
        i.user_id == ^user_id and i.media_type == ^media_type and i.provider == ^provider and
          i.provider_id == ^provider_id
    )
    |> Repo.delete_all()

    :ok
  end

  @doc "The user's ignored titles as a set of `{media_type, ref}` keys."
  @spec keys(User.t()) :: MapSet.t(key())
  def keys(%User{id: user_id}) do
    from(i in IgnoredDiscoverTitle,
      where: i.user_id == ^user_id,
      select: {i.media_type, i.provider, i.provider_id}
    )
    |> Repo.all()
    |> MapSet.new(fn {media_type, provider, id} ->
      {media_type(media_type), {provider(provider), id}}
    end)
  end

  @doc """
  The key for a search result. `fallback_media_type` covers results that carry
  no media type of their own (a curated page's items), the same fallback the
  Discover grid uses when rendering them.
  """
  @spec key_for(map(), :movie | :tv_show | nil) :: key()
  def key_for(item, fallback_media_type) do
    {Map.get(item, :media_type) || fallback_media_type, Ref.from_search_result(item)}
  end

  @doc "Whether `item` is in `keys`, a set from keys/1."
  @spec ignored?(MapSet.t(key()), :movie | :tv_show | nil, map()) :: boolean()
  def ignored?(keys, fallback_media_type, item) do
    MapSet.size(keys) > 0 and MapSet.member?(keys, key_for(item, fallback_media_type))
  end

  defp media_type("movie"), do: :movie
  defp media_type("tv_show"), do: :tv_show
  defp provider("tmdb"), do: :tmdb
  defp provider("tvdb"), do: :tvdb
end
