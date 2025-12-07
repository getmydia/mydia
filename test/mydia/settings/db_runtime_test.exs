defmodule Mydia.DBRuntimeTest do
  @moduledoc """
  Tests for runtime database adapter selection in Mydia.DB.

  This module validates that dynamic-based functions can switch
  between SQLite and PostgreSQL SQL syntax at runtime.
  """
  use Mydia.DataCase

  import Ecto.Query
  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  alias Mydia.Repo
  alias Mydia.Downloads.Download
  alias Mydia.Media.MediaItem

  describe "runtime functions - SQLite (current config)" do
    test "json_equals/3 returns dynamic that works with SQLite" do
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "download_client" => "qbittorrent"
          }
        })

      # Use the runtime function from Mydia.DB
      cond = Mydia.DB.json_equals(:metadata, "$.download_client", "qbittorrent")

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: ^cond,
          select: d.id
        )
        |> Repo.one()

      assert result == download.id
    end

    test "json_equals/3 returns nil for non-matching value" do
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "download_client" => "qbittorrent"
          }
        })

      cond = Mydia.DB.json_equals(:metadata, "$.download_client", "transmission")

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: ^cond,
          select: d.id
        )
        |> Repo.one()

      assert result == nil
    end

    test "json_integer_equals/3 works with SQLite" do
      media_item = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "season_number" => 3
          }
        })

      cond = Mydia.DB.json_integer_equals(:metadata, "$.season_number", 3)

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: ^cond,
          select: d.id
        )
        |> Repo.one()

      assert result == download.id
    end

    test "json_integer_equals/3 returns nil for non-matching value" do
      media_item = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "season_number" => 3
          }
        })

      cond = Mydia.DB.json_integer_equals(:metadata, "$.season_number", 5)

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: ^cond,
          select: d.id
        )
        |> Repo.one()

      assert result == nil
    end

    test "json_is_true/2 works with boolean true" do
      media_item = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "season_pack" => true
          }
        })

      bool_cond = Mydia.DB.json_is_true(:metadata, "$.season_pack")

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: ^bool_cond,
          select: d.id
        )
        |> Repo.one()

      assert result == download.id
    end

    test "json_is_true/2 returns nil for boolean false" do
      media_item = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "season_pack" => false
          }
        })

      bool_cond = Mydia.DB.json_is_true(:metadata, "$.season_pack")

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: ^bool_cond,
          select: d.id
        )
        |> Repo.one()

      assert result == nil
    end

    test "json_is_not_null/2 returns records with non-null value" do
      item_with_date =
        media_item_fixture(%{
          metadata: %{"release_date" => "2024-01-15"}
        })

      cond = Mydia.DB.json_is_not_null(:metadata, "$.release_date")

      result =
        from(m in MediaItem,
          where: m.id == ^item_with_date.id,
          where: ^cond,
          select: m.id
        )
        |> Repo.one()

      assert result == item_with_date.id
    end

    test "json_is_not_null/2 excludes records with null/missing value" do
      item_without_date =
        media_item_fixture(%{
          metadata: %{"other_field" => "value"}
        })

      cond = Mydia.DB.json_is_not_null(:metadata, "$.release_date")

      result =
        from(m in MediaItem,
          where: m.id == ^item_without_date.id,
          where: ^cond,
          select: m.id
        )
        |> Repo.one()

      assert result == nil
    end

    test "json_is_null/2 returns records with null/missing value" do
      item_without_date =
        media_item_fixture(%{
          metadata: %{"other_field" => "value"}
        })

      cond = Mydia.DB.json_is_null(:metadata, "$.release_date")

      result =
        from(m in MediaItem,
          where: m.id == ^item_without_date.id,
          where: ^cond,
          select: m.id
        )
        |> Repo.one()

      assert result == item_without_date.id
    end
  end

  describe "runtime functions - verify compile includes both branches" do
    test "module exports all runtime functions" do
      # Verify all runtime functions are exported
      assert function_exported?(Mydia.DB, :json_equals, 3)
      assert function_exported?(Mydia.DB, :json_integer_equals, 3)
      assert function_exported?(Mydia.DB, :json_is_true, 2)
      assert function_exported?(Mydia.DB, :json_is_not_null, 2)
      assert function_exported?(Mydia.DB, :json_is_null, 2)
    end

    test "adapter_type returns configured type" do
      # Verify adapter functions are consistent
      adapter = Mydia.DB.adapter_type()
      assert adapter in [:sqlite, :postgres]

      case adapter do
        :sqlite ->
          assert Mydia.DB.sqlite?() == true
          assert Mydia.DB.postgres?() == false

        :postgres ->
          assert Mydia.DB.sqlite?() == false
          assert Mydia.DB.postgres?() == true
      end
    end
  end
end
