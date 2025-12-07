defmodule Mydia.ImportListsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Mydia.ImportLists` context.
  """

  alias Mydia.ImportLists

  @doc """
  Generate an import list.
  """
  def import_list_fixture(attrs \\ %{}) do
    {:ok, import_list} =
      attrs
      |> Enum.into(%{
        name: "Test Import List #{System.unique_integer([:positive])}",
        type: "tmdb_trending",
        media_type: "movie",
        enabled: true,
        sync_interval: 360,
        auto_add: false,
        monitored: true
      })
      |> ImportLists.create_import_list()

    import_list
  end

  @doc """
  Generate an import list item.
  """
  def import_list_item_fixture(import_list, attrs \\ %{}) do
    {:ok, item} =
      attrs
      |> Enum.into(%{
        import_list_id: import_list.id,
        tmdb_id: System.unique_integer([:positive]) + 10000,
        title: "Test Movie #{System.unique_integer([:positive])}",
        year: 2024,
        status: "pending",
        discovered_at: DateTime.utc_now()
      })
      |> ImportLists.create_import_list_item()

    item
  end
end
