defmodule Mydia.Plugins.Shelves do
  @moduledoc """
  Plugin shelves: named, ordered lists of titles a plugin fills and the host
  stores, verifies and renders.

  A plugin declares a shelf in its manifest (`shelves`, under `surfaces:shelf`)
  and returns ids and reasons from its `fill-shelf` export. Everything else is
  here: which shelves exist, whose row is whose, when a row is stale, and what
  a user dismissed. The fill itself is in this module too (`fill/3`), run by
  `Mydia.Jobs.ShelfFill`.

  This is the only module that reads or writes the three shelf tables.
  """

  import Ecto.Query

  alias Mydia.Accounts.User
  alias Mydia.Media.ProviderKey
  alias Mydia.Plugins
  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.ShelfDismissal
  alias Mydia.Plugins.ShelfItem
  alias Mydia.Plugins.Shelves.Declared
  alias Mydia.Plugins.Shelves.View
  alias Mydia.Repo

  @capability "surfaces:shelf"

  # ── Declarations ──────────────────────────────────────────────────────────

  @doc "Every shelf declared by an enabled plugin holding `surfaces:shelf`."
  @spec declared() :: [Declared.t()]
  def declared do
    for %Plugin{enabled: true, shelves: shelves} = plugin <- Plugins.list_plugins(),
        Plugin.granted?(plugin, @capability),
        shelf <- shelves do
      %Declared{
        slug: plugin.slug,
        key: shelf["key"],
        title: shelf["title"],
        placement: shelf["placement"],
        scope: shelf["scope"],
        ttl_seconds: shelf["ttl_seconds"],
        refresh_on: shelf["refresh_on"] || []
      }
    end
  end

  @doc "The declared shelves for one placement, such as `:home`."
  @spec declared(atom() | String.t()) :: [Declared.t()]
  def declared(placement) do
    placement = to_string(placement)
    Enum.filter(declared(), &(&1.placement == placement))
  end

  @doc "One declared shelf, or `nil` when the plugin no longer declares it."
  @spec get_declared(String.t(), String.t()) :: Declared.t() | nil
  def get_declared(slug, key), do: Enum.find(declared(), &(&1.slug == slug and &1.key == key))

  # ── Reading ───────────────────────────────────────────────────────────────

  @doc """
  The user's shelves for a placement, with whatever items they currently hold.

  Returns immediately from the database. A shelf the user has never seen gets
  its row here and reads as stale; filling it is the caller's next step
  (`refresh_stale/1`).
  """
  @spec list_for(User.t(), atom() | String.t(), DateTime.t()) :: [View.t()]
  def list_for(%User{} = user, placement, now \\ DateTime.utc_now()) do
    for %Declared{} = declared <- declared(placement) do
      shelf = ensure_shelf(declared, user)
      %View{declared: declared, shelf: shelf, items: items(shelf), stale?: stale?(shelf, now)}
    end
  end

  @doc "True when the shelf has never been filled or its `stale_at` has passed."
  @spec stale?(Shelf.t(), DateTime.t()) :: boolean()
  def stale?(%Shelf{stale_at: nil}, _now), do: true
  def stale?(%Shelf{stale_at: stale_at}, now), do: DateTime.compare(now, stale_at) != :lt

  defp ensure_shelf(%Declared{slug: slug, key: key}, %User{id: user_id}) do
    identity = [plugin_slug: slug, shelf_key: key, user_id: user_id]

    Repo.get_by(Shelf, identity) ||
      (
        Repo.insert!(struct!(Shelf, identity),
          on_conflict: :nothing,
          conflict_target: [:plugin_slug, :shelf_key, :user_id]
        )

        Repo.get_by!(Shelf, identity)
      )
  end

  defp items(%Shelf{id: id}) do
    Repo.all(from i in ShelfItem, where: i.shelf_id == ^id, order_by: [asc: i.position])
  end

  # ── Dismissals ────────────────────────────────────────────────────────────

  @doc """
  Records that `user` is not interested in an item and removes its card.

  The dismissal is keyed on the shelf's plugin and key, so the next fill
  excludes the title even though the item row is gone.
  """
  @spec dismiss_item(User.t(), String.t()) :: :ok | {:error, :not_found}
  def dismiss_item(%User{id: user_id}, item_id) do
    with {:ok, id} <- Ecto.UUID.cast(item_id),
         %ShelfItem{shelf: %Shelf{user_id: ^user_id} = shelf} = item <-
           ShelfItem |> Repo.get(id) |> Repo.preload(:shelf) do
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.insert!(
            %ShelfDismissal{
              plugin_slug: shelf.plugin_slug,
              shelf_key: shelf.shelf_key,
              user_id: user_id,
              media_type: item.media_type,
              provider: item.provider,
              provider_id: item.provider_id
            },
            on_conflict: :nothing,
            conflict_target: [
              :plugin_slug,
              :shelf_key,
              :user_id,
              :media_type,
              :provider,
              :provider_id
            ]
          )

          Repo.delete!(item)
        end)

      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The titles this shelf's user dismissed, as provider keys."
  @spec dismissed_keys(Shelf.t()) :: MapSet.t(ProviderKey.t())
  def dismissed_keys(%Shelf{} = shelf) do
    from(d in ShelfDismissal,
      where:
        d.plugin_slug == ^shelf.plugin_slug and d.shelf_key == ^shelf.shelf_key and
          d.user_id == ^shelf.user_id,
      select: {d.media_type, d.provider, d.provider_id}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # ── Lifecycle ─────────────────────────────────────────────────────────────

  @doc "Deletes every shelf, item and dismissal of a plugin. Called on revoke and remove."
  @spec purge(String.t()) :: :ok
  def purge(slug) when is_binary(slug) do
    # Items go with their shelf through the foreign key.
    Repo.delete_all(from s in Shelf, where: s.plugin_slug == ^slug)
    Repo.delete_all(from d in ShelfDismissal, where: d.plugin_slug == ^slug)
    :ok
  end

  # ── Live updates ──────────────────────────────────────────────────────────

  @doc "The PubSub topic a user's shelf updates are broadcast on."
  @spec topic(String.t()) :: String.t()
  def topic(user_id), do: "plugin_shelves:#{user_id}"

  @doc "Subscribes the caller to `{:shelf_updated, shelf_id}` for this user."
  @spec subscribe(User.t()) :: :ok
  def subscribe(%User{id: user_id}),
    do: Phoenix.PubSub.subscribe(Mydia.PubSub, topic(user_id))
end
