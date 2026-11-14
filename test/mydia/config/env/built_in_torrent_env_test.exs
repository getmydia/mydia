defmodule Mydia.Config.Env.BuiltInTorrentEnvTest do
  use ExUnit.Case, async: true

  alias Mydia.Config.Env.BuiltInTorrentEnv

  test "reads seeding and limit variables" do
    env = %{
      "MYDIA_TORRENT_SEED_RATIO" => "1.5",
      "MYDIA_TORRENT_SEED_TIME" => "4320",
      "MYDIA_TORRENT_SEED_GOAL_ACTION" => "Remove",
      "MYDIA_TORRENT_DOWNLOAD_LIMIT" => "0",
      "MYDIA_TORRENT_UPLOAD_LIMIT" => "512"
    }

    assert %{
             seed_ratio: 1.5,
             seed_time: 4320,
             seed_goal_action: "remove",
             download_limit: 0,
             upload_limit: 512
           } = BuiltInTorrentEnv.load(&env[&1])
  end

  test "accepts an integer ratio" do
    env = %{"MYDIA_TORRENT_SEED_RATIO" => "2"}
    assert %{seed_ratio: 2.0} = BuiltInTorrentEnv.load(&env[&1])
  end

  test "drops unparseable or out-of-range values" do
    env = %{
      "MYDIA_TORRENT_SEED_RATIO" => "-1",
      "MYDIA_TORRENT_SEED_TIME" => "abc",
      "MYDIA_TORRENT_SEED_GOAL_ACTION" => "delete",
      "MYDIA_TORRENT_DOWNLOAD_LIMIT" => "-5",
      "MYDIA_TORRENT_UPLOAD_LIMIT" => "1.5"
    }

    loaded = BuiltInTorrentEnv.load(&env[&1])

    for key <- [:seed_ratio, :seed_time, :seed_goal_action, :download_limit, :upload_limit] do
      refute Map.has_key?(loaded, key)
    end
  end
end
