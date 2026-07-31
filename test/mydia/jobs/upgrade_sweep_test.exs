defmodule Mydia.Jobs.UpgradeSweepTest do
  use Mydia.DataCase, async: false

  import Mydia.Factory
  import Mydia.SettingsFixtures

  alias Mydia.Jobs.UpgradeSweep

  setup do
    original = Application.get_env(:mydia, :runtime_config)
    put_upgrades_config(sweep_enabled: true, sweep_batch_size: 10)

    on_exit(fn ->
      if original do
        Application.put_env(:mydia, :runtime_config, original)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    :ok
  end

  # Overrides only the :upgrades embed of the layered runtime config
  # (Mydia.Config.get().upgrades), which is what UpgradeSweep.enabled?/0 and
  # .batch_size/0 actually read. Setting the old flat
  # Application.put_env(:mydia, :upgrade_sweep_enabled, ...) key here would
  # be silently ignored by the job — see the comments on enabled?/0 and
  # batch_size/0 in lib/mydia/jobs/upgrade_sweep.ex.
  defp put_upgrades_config(attrs) do
    defaults = Mydia.Config.Schema.defaults()
    upgrades = struct(defaults.upgrades, attrs)
    Application.put_env(:mydia, :runtime_config, %{defaults | upgrades: upgrades})
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

  # NOTE: this proves stamping happens when a candidate's enqueue succeeds —
  # the only case this test suite can construct. It does NOT, by itself,
  # prove the item is stamped when its enqueue *fails* (the actual
  # anti-starvation guarantee decisions #2/#3 in the task brief describe):
  # every candidate here succeeds, since Repo.insert/1 (the fallback
  # insert_job/1 uses under config/test.exs's engine: false) never fails for
  # a well-formed MovieSearch changeset in this codebase — there is no FK or
  # unique DB constraint tied to the business ids carried in `args`, and this
  # project has no mocking library wired up to stub Repo.insert/1 or
  # Oban.insert/1. See the comment on enqueue_movie/1 in
  # lib/mydia/jobs/upgrade_sweep.ex for the full reasoning trail.
  test "stamps the candidate it successfully enqueues" do
    movie = eligible_movie()

    assert {:ok, _} = UpgradeSweep.perform(%Oban.Job{args: %{}})
    assert Repo.reload!(movie).last_upgrade_check_at
  end

  test "does nothing when the sweep is disabled" do
    movie = eligible_movie()
    put_upgrades_config(sweep_enabled: false, sweep_batch_size: 10)

    assert {:ok, :disabled} = UpgradeSweep.perform(%Oban.Job{args: %{}})
    refute Repo.reload!(movie).last_upgrade_check_at
  end

  test "never enqueues more searches than the batch size" do
    for _ <- 1..5, do: eligible_movie()
    put_upgrades_config(sweep_enabled: true, sweep_batch_size: 2)

    assert {:ok, %{searches: 2}} = UpgradeSweep.perform(%Oban.Job{args: %{}})
  end
end
