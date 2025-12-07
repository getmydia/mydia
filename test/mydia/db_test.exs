defmodule Mydia.DBTest do
  use Mydia.DataCase

  import Ecto.Query
  import Mydia.DB
  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  alias Mydia.Repo
  alias Mydia.Downloads.Download
  alias Mydia.Media.MediaItem

  describe "adapter detection" do
    test "adapter_type/0 returns configured adapter type" do
      # Test that adapter_type returns a valid database type
      assert Mydia.DB.adapter_type() in [:sqlite, :postgres]
    end

    test "sqlite?/0 and postgres?/0 are mutually exclusive" do
      # One must be true, the other false
      assert Mydia.DB.sqlite?() != Mydia.DB.postgres?()
    end

    test "adapter functions match adapter_type/0" do
      case Mydia.DB.adapter_type() do
        :sqlite ->
          assert Mydia.DB.sqlite?() == true
          assert Mydia.DB.postgres?() == false

        :postgres ->
          assert Mydia.DB.sqlite?() == false
          assert Mydia.DB.postgres?() == true
      end
    end
  end

  describe "sqlite_path_to_postgres_key/1" do
    test "converts $.key to key" do
      assert Mydia.DB.sqlite_path_to_postgres_key("$.download_client") == "download_client"
    end

    test "converts $.nested.key to nested.key" do
      assert Mydia.DB.sqlite_path_to_postgres_key("$.foo.bar") == "foo.bar"
    end

    test "handles path without $ prefix" do
      assert Mydia.DB.sqlite_path_to_postgres_key("key") == "key"
    end
  end

  describe "json_extract/2" do
    test "extracts string value from JSON field" do
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "download_client" => "qbittorrent",
            "download_client_id" => "abc123"
          }
        })

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: json_extract(d.metadata, "$.download_client") == "qbittorrent",
          select: d.id
        )
        |> Repo.one()

      assert result == download.id
    end

    test "extracts and compares with pinned variable" do
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "download_client" => "qbittorrent"
          }
        })

      client_name = "qbittorrent"

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: json_extract(d.metadata, "$.download_client") == ^client_name,
          select: d.id
        )
        |> Repo.one()

      assert result == download.id
    end

    test "returns nil for non-matching value" do
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "download_client" => "qbittorrent"
          }
        })

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: json_extract(d.metadata, "$.download_client") == "transmission",
          select: d.id
        )
        |> Repo.one()

      assert result == nil
    end
  end

  describe "json_extract_integer/2" do
    test "extracts integer value from JSON field" do
      media_item = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "season_number" => 3,
            "episode_count" => 10
          }
        })

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: json_extract_integer(d.metadata, "$.season_number") == 3,
          select: d.id
        )
        |> Repo.one()

      assert result == download.id
    end

    test "extracts and compares with pinned integer variable" do
      media_item = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "season_number" => 3
          }
        })

      season_number = 3

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: json_extract_integer(d.metadata, "$.season_number") == ^season_number,
          select: d.id
        )
        |> Repo.one()

      assert result == download.id
    end

    test "returns nil for non-matching integer" do
      media_item = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "season_number" => 3
          }
        })

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: json_extract_integer(d.metadata, "$.season_number") == 5,
          select: d.id
        )
        |> Repo.one()

      assert result == nil
    end
  end

  describe "json_extract_boolean/2" do
    test "returns true for boolean true value" do
      media_item = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "season_pack" => true
          }
        })

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: json_extract_boolean(d.metadata, "$.season_pack"),
          select: d.id
        )
        |> Repo.one()

      assert result == download.id
    end

    test "returns nil for boolean false value" do
      media_item = media_item_fixture(%{type: "tv_show"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{
            "season_pack" => false
          }
        })

      result =
        from(d in Download,
          where: d.id == ^download.id,
          where: json_extract_boolean(d.metadata, "$.season_pack"),
          select: d.id
        )
        |> Repo.one()

      assert result == nil
    end

    test "filters correctly with boolean condition" do
      media_item = media_item_fixture(%{type: "tv_show"})

      download_true =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{"season_pack" => true}
        })

      download_false =
        download_fixture(%{
          media_item_id: media_item.id,
          metadata: %{"season_pack" => false}
        })

      results =
        from(d in Download,
          where: d.id in [^download_true.id, ^download_false.id],
          where: json_extract_boolean(d.metadata, "$.season_pack"),
          select: d.id
        )
        |> Repo.all()

      assert results == [download_true.id]
    end
  end

  describe "json_not_null/2" do
    test "returns records with non-null JSON value" do
      item_with_date =
        media_item_fixture(%{
          metadata: %{"release_date" => "2024-01-15"}
        })

      result =
        from(m in MediaItem,
          where: m.id == ^item_with_date.id,
          where: json_not_null(m.metadata, "$.release_date"),
          select: m.id
        )
        |> Repo.one()

      assert result == item_with_date.id
    end

    test "excludes records with null/missing JSON value" do
      item_without_date =
        media_item_fixture(%{
          metadata: %{"other_field" => "value"}
        })

      result =
        from(m in MediaItem,
          where: m.id == ^item_without_date.id,
          where: json_not_null(m.metadata, "$.release_date"),
          select: m.id
        )
        |> Repo.one()

      assert result == nil
    end

    test "filters correctly across multiple records" do
      with_date =
        media_item_fixture(%{
          metadata: %{"release_date" => "2024-01-15"}
        })

      without_date =
        media_item_fixture(%{
          metadata: %{"other_field" => "value"}
        })

      results =
        from(m in MediaItem,
          where: m.id in [^with_date.id, ^without_date.id],
          where: json_not_null(m.metadata, "$.release_date"),
          select: m.id
        )
        |> Repo.all()

      assert results == [with_date.id]
    end
  end

  describe "exists_check/2" do
    test "returns false when subquery has no results" do
      media_item = media_item_fixture()

      result =
        from(m in MediaItem,
          where: m.id == ^media_item.id,
          select: %{
            id: m.id,
            has_downloads: exists_check("SELECT 1 FROM downloads WHERE media_item_id = ?", m.id)
          }
        )
        |> Repo.one()

      # No downloads exist for this media item
      assert result.id == media_item.id
      # SQLite returns 0/1 for false/true
      assert result.has_downloads in [false, 0]
    end

    test "returns true when subquery has results" do
      media_item = media_item_fixture()

      # Create a download for the media item
      _download = download_fixture(%{media_item_id: media_item.id})

      result =
        from(m in MediaItem,
          where: m.id == ^media_item.id,
          select: %{
            id: m.id,
            has_downloads: exists_check("SELECT 1 FROM downloads WHERE media_item_id = ?", m.id)
          }
        )
        |> Repo.one()

      assert result.id == media_item.id
      # SQLite returns 1 for true
      assert result.has_downloads in [true, 1]
    end
  end

  describe "cast_to_real/1" do
    test "casts value to float in select" do
      media_item = media_item_fixture()

      result =
        from(m in MediaItem,
          where: m.id == ^media_item.id,
          select: cast_to_real(1)
        )
        |> Repo.one()

      assert result == 1.0
    end
  end

  describe "cast_to_integer/1" do
    test "casts value to integer in select" do
      media_item = media_item_fixture()

      result =
        from(m in MediaItem,
          where: m.id == ^media_item.id,
          select: cast_to_integer(1.9)
        )
        |> Repo.one()

      # SQLite truncates (floor), PostgreSQL rounds, so accept either
      assert result in [1, 2]
    end
  end

  describe "timestamp_diff_seconds/2" do
    test "calculates difference between timestamps" do
      now = DateTime.utc_now()
      one_hour_ago = DateTime.add(now, -3600, :second)

      media_item = media_item_fixture()

      # Update the timestamps directly in the database
      from(m in MediaItem,
        where: m.id == ^media_item.id,
        update: [set: [inserted_at: ^one_hour_ago, updated_at: ^now]]
      )
      |> Repo.update_all([])

      result =
        from(m in MediaItem,
          where: m.id == ^media_item.id,
          select: timestamp_diff_seconds(m.updated_at, m.inserted_at)
        )
        |> Repo.one()

      # PostgreSQL returns Decimal, SQLite returns float - convert to float for comparison
      result_float = if is_struct(result, Decimal), do: Decimal.to_float(result), else: result

      # Allow for small timing differences (within 5 seconds)
      assert_in_delta result_float, 3600.0, 5.0
    end
  end

  describe "avg_timestamp_diff_seconds/2" do
    test "calculates average difference between timestamps" do
      now = DateTime.utc_now()
      one_hour_ago = DateTime.add(now, -3600, :second)
      two_hours_ago = DateTime.add(now, -7200, :second)

      item1 = media_item_fixture()
      item2 = media_item_fixture()

      # Update timestamps for both items
      from(m in MediaItem,
        where: m.id == ^item1.id,
        update: [set: [inserted_at: ^one_hour_ago, updated_at: ^now]]
      )
      |> Repo.update_all([])

      from(m in MediaItem,
        where: m.id == ^item2.id,
        update: [set: [inserted_at: ^two_hours_ago, updated_at: ^now]]
      )
      |> Repo.update_all([])

      result =
        from(m in MediaItem,
          where: m.id in [^item1.id, ^item2.id],
          select: avg_timestamp_diff_seconds(m.updated_at, m.inserted_at)
        )
        |> Repo.one()

      # PostgreSQL returns Decimal, SQLite returns float - convert to float for comparison
      result_float = if is_struct(result, Decimal), do: Decimal.to_float(result), else: result

      # Average of 3600 and 7200 seconds = 5400 seconds
      # Allow for small timing differences
      assert_in_delta result_float, 5400.0, 10.0
    end
  end
end
