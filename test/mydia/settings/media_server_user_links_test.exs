defmodule Mydia.Settings.MediaServerUserLinksTest do
  @moduledoc """
  The writes underneath every mapping producer.

  One rule matters more than the rest here: two Mydia users must never end up
  pointed at one remote account. Watched sync enqueues one job per link, so a
  pair of links naming the same account imports that account's history under two
  different people, which is the merge per-user mapping exists to prevent.
  """
  use Mydia.DataCase, async: true

  alias Mydia.AccountsFixtures
  alias Mydia.Settings

  setup do
    {:ok, config} =
      Settings.create_media_server_config(%{
        name: "Server #{System.unique_integer([:positive])}",
        type: :jellyfin,
        url: "http://localhost:8096",
        token: "api-key"
      })

    %{
      config: config,
      alex: AccountsFixtures.user_fixture(%{username: "alex"}),
      sarah: AccountsFixtures.user_fixture(%{username: "sarah"})
    }
  end

  describe "upsert_media_server_user_link/2" do
    test "refuses an account another Mydia user already holds", ctx do
      assert {:ok, _} = upsert(ctx.config, ctx.alex, "guid-1")
      assert {:error, :account_already_mapped} = upsert(ctx.config, ctx.sarah, "guid-1")

      assert [link] = Settings.list_media_server_user_links(ctx.config.id)
      assert link.user_id == ctx.alex.id
    end

    test "re-saving a user's own mapping is not read as someone else's claim", ctx do
      assert {:ok, _} = upsert(ctx.config, ctx.alex, "guid-1")
      assert {:ok, _} = upsert(ctx.config, ctx.alex, "guid-1")
    end
  end

  describe "replace_media_server_user_links/2" do
    test "refuses an entry set that names one account twice", ctx do
      # This is the writer master added for the mapping modal, and it is a
      # second door into the same table. Without this check the row-by-row guard
      # is skipped for the bulk path and the double claim reopens.
      assert {:error, :duplicate_remote_account} =
               Settings.replace_media_server_user_links(ctx.config.id, [
                 entry(ctx.config, ctx.alex, "guid-1"),
                 entry(ctx.config, ctx.sarah, "guid-1")
               ])

      assert Settings.list_media_server_user_links(ctx.config.id) == []
    end

    test "leaves the stored mapping untouched when it refuses", ctx do
      assert {:ok, _} = upsert(ctx.config, ctx.alex, "guid-1")

      assert {:error, :duplicate_remote_account} =
               Settings.replace_media_server_user_links(ctx.config.id, [
                 entry(ctx.config, ctx.alex, "guid-2"),
                 entry(ctx.config, ctx.sarah, "guid-2")
               ])

      assert [link] = Settings.list_media_server_user_links(ctx.config.id)
      assert link.remote_user_id == "guid-1"
    end

    test "applies a swap that the row-by-row guard would refuse", ctx do
      # Replacing the whole set atomically transiently looks like a conflict
      # with rows it is about to overwrite. What has to hold is the final state.
      assert {:ok, _} =
               Settings.replace_media_server_user_links(ctx.config.id, [
                 entry(ctx.config, ctx.alex, "guid-1"),
                 entry(ctx.config, ctx.sarah, "guid-2")
               ])

      assert {:ok, _} =
               Settings.replace_media_server_user_links(ctx.config.id, [
                 entry(ctx.config, ctx.alex, "guid-2"),
                 entry(ctx.config, ctx.sarah, "guid-1")
               ])

      links = Settings.list_media_server_user_links(ctx.config.id)
      assert Enum.find(links, &(&1.user_id == ctx.alex.id)).remote_user_id == "guid-2"
      assert Enum.find(links, &(&1.user_id == ctx.sarah.id)).remote_user_id == "guid-1"
    end

    test "deletes the link of a user the entry set does not name", ctx do
      assert {:ok, _} = upsert(ctx.config, ctx.alex, "guid-1")
      assert {:ok, _} = upsert(ctx.config, ctx.sarah, "guid-2")

      assert {:ok, [_]} =
               Settings.replace_media_server_user_links(ctx.config.id, [
                 entry(ctx.config, ctx.alex, "guid-1")
               ])

      assert [link] = Settings.list_media_server_user_links(ctx.config.id)
      assert link.user_id == ctx.alex.id
    end

    test "does not touch links belonging to another server", ctx do
      {:ok, other_config} =
        Settings.create_media_server_config(%{
          name: "Other #{System.unique_integer([:positive])}",
          type: :jellyfin,
          url: "http://localhost:8096",
          token: "api-key"
        })

      assert {:ok, _} = upsert(other_config, ctx.alex, "guid-1")

      assert {:ok, []} = Settings.replace_media_server_user_links(ctx.config.id, [])

      assert [kept] = Settings.list_media_server_user_links(other_config.id)
      assert kept.remote_user_id == "guid-1"
    end
  end

  defp upsert(config, user, remote_user_id) do
    Settings.upsert_media_server_user_link(entry(config, user, remote_user_id))
  end

  defp entry(config, user, remote_user_id) do
    %{
      media_server_config_id: config.id,
      user_id: user.id,
      remote_user_id: remote_user_id,
      remote_username: user.username,
      enabled: true
    }
  end
end
