defmodule Mydia.ShelfHelpers do
  @moduledoc """
  Registers a plugin descriptor that declares a shelf, without starting a wasm
  pool, and builds shelf rows. Registers `on_exit` cleanup, so call
  `register_shelf_plugin!/1` from a test or `setup` block.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Mydia.Plugins.Plugin
  alias Mydia.Plugins.Registry
  alias Mydia.Plugins.Shelf
  alias Mydia.Plugins.ShelfItem
  alias Mydia.Repo

  @spec register_shelf_plugin!(keyword()) :: String.t()
  def register_shelf_plugin!(opts \\ []) do
    slug = Keyword.get(opts, :slug, "shelf-test")

    shelf = %{
      "key" => Keyword.get(opts, :key, "picks"),
      "title" => Keyword.get(opts, :title, "Picked for you"),
      "placement" => "home",
      "scope" => "user",
      "ttl_seconds" => Keyword.get(opts, :ttl_seconds, 86_400),
      "refresh_on" => Keyword.get(opts, :refresh_on, ["playback.finished"])
    }

    {:ok, _} =
      Registry.register(slug, %Plugin{
        slug: slug,
        name: "Shelf Test",
        enabled: Keyword.get(opts, :enabled, true),
        granted_capabilities: Keyword.get(opts, :granted, %{"surfaces:shelf" => []}),
        shelves: [shelf]
      })

    on_exit(fn -> Registry.unregister(slug) end)
    slug
  end

  @spec shelf_fixture(Mydia.Accounts.User.t(), keyword()) :: Shelf.t()
  def shelf_fixture(user, opts \\ []) do
    Repo.insert!(%Shelf{
      plugin_slug: Keyword.get(opts, :slug, "shelf-test"),
      shelf_key: Keyword.get(opts, :key, "picks"),
      user_id: user.id,
      filled_at: Keyword.get(opts, :filled_at),
      stale_at: Keyword.get(opts, :stale_at)
    })
  end

  @spec shelf_item_fixture(Shelf.t(), map()) :: ShelfItem.t()
  def shelf_item_fixture(shelf, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        %ShelfItem{
          shelf_id: shelf.id,
          position: 0,
          media_type: :movie,
          provider: :tmdb,
          provider_id: 101,
          title: "Ember Tide",
          year: 2024,
          reason: "Because you finished Glass Meridian"
        },
        attrs
      )
    )
  end
end
