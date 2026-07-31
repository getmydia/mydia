defmodule Mydia.Jobs.UpgradeSweepTest do
  use Mydia.DataCase, async: false

  import Mydia.Factory
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.UpgradeSweep

  setup do
    Application.put_env(:mydia, :upgrade_sweep_enabled, true)
    Application.put_env(:mydia, :upgrade_sweep_batch_size, 10)
    on_exit(fn -> Application.delete_env(:mydia, :upgrade_sweep_enabled) end)
    :ok
  end

  defp eligible_movie do
    profile =
      quality_profile_fixture(%{
        name: "Sweep #{System.unique_integer([:positive])}",
        upgrades_allowed: true,
        upgrade_until_score: 100,
        quality_standards: %{preferred_resolutions: ["2160p"]}
      })

    movie = insert(:media_item, type: "movie", monitored: true, quality_profile: profile)

    insert(:media_file,
      media_item: movie,
      episode: nil,
      resolution: "720p",
      codec: "H.264 (High)",
      size: 2 * 1024 * 1024 * 1024,
      analyzed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      quality_profile: profile
    )

    movie
  end

  test "stamps every item it enqueues, so the rotation always advances" do
    movie = eligible_movie()

    assert {:ok, _} = UpgradeSweep.perform(%Oban.Job{args: %{}})
    assert Repo.reload!(movie).last_upgrade_check_at
  end

  test "does nothing when the sweep is disabled" do
    movie = eligible_movie()
    Application.put_env(:mydia, :upgrade_sweep_enabled, false)

    assert {:ok, :disabled} = UpgradeSweep.perform(%Oban.Job{args: %{}})
    refute Repo.reload!(movie).last_upgrade_check_at
  end

  test "never enqueues more searches than the batch size" do
    for _ <- 1..5, do: eligible_movie()
    Application.put_env(:mydia, :upgrade_sweep_batch_size, 2)

    assert {:ok, %{searches: 2}} = UpgradeSweep.perform(%Oban.Job{args: %{}})
  end
end
