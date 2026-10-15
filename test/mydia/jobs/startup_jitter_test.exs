defmodule Mydia.Jobs.StartupJitterTest do
  use Mydia.DataCase, async: false

  alias Mydia.Jobs.{AiringEpisodeRefresh, MetadataRefresh, StartupJitter}

  describe "delay/2" do
    test "snoozes a job that has never snoozed" do
      job = %Oban.Job{attempt: 1, meta: %{}}

      assert {:snooze, seconds} = StartupJitter.delay(job, 60)
      assert seconds in 1..60
    end

    # Oban 2.24 rolls attempt back on snooze, so this is exactly what the
    # wake-up looks like. Gating on attempt == 1 snoozed it forever.
    test "runs a job that has snoozed, even though attempt is still 1" do
      assert :run = StartupJitter.delay(%Oban.Job{attempt: 1, meta: %{"snoozed" => 1}}, 60)
    end

    test "runs a retried job that snoozed before failing" do
      assert :run = StartupJitter.delay(%Oban.Job{attempt: 2, meta: %{"snoozed" => 1}}, 60)
    end
  end

  # perform_job/3 takes attempt and meta from the caller, so it can only test
  # the model of Oban the test author had in mind. Draining a real queue runs
  # Oban's own snooze bookkeeping, which is the thing that changed under us.
  describe "against a real Oban engine" do
    setup do
      engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
      start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})
      :ok
    end

    for {worker, args} <- [
          {AiringEpisodeRefresh, %{"scope" => "all"}},
          {MetadataRefresh, %{"refresh_all" => true}}
        ] do
      test "#{inspect(worker)} snoozes once and then runs" do
        assert {:ok, _job} = Oban.insert(unquote(worker).new(unquote(Macro.escape(args))))

        assert %{snoozed: 1, success: 0} = Oban.drain_queue(queue: :media)

        assert %{snoozed: 0, success: 1} =
                 Oban.drain_queue(queue: :media, with_scheduled: true)
      end
    end
  end

  describe "source guard" do
    @helper Path.expand("lib/mydia/jobs/startup_jitter.ex")

    # A snooze decided anywhere else can repeat the attempt == 1 mistake.
    test "every snooze in lib/ goes through StartupJitter" do
      offenders =
        for path <- Path.wildcard("lib/**/*.ex"),
            Path.expand(path) != @helper,
            {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
            snooze_tuple?(line),
            do: "#{path}:#{number}: #{String.trim(line)}"

      assert offenders == [],
             "Build snoozes with Mydia.Jobs.StartupJitter.delay/2, not a literal tuple:\n" <>
               Enum.join(offenders, "\n")
    end

    test "no worker gates a snooze on the attempt number" do
      offenders =
        for path <- Path.wildcard("lib/**/*.ex"),
            Path.expand(path) != @helper,
            source = File.read!(path),
            String.contains?(source, ["StartupJitter.delay", ":snooze"]),
            Regex.match?(~r/attempt\s*(==\s*1|<=\s*1|<\s*2)\b/, source),
            do: path

      assert offenders == [],
             "Oban rolls attempt back on snooze; read meta[\"snoozed\"] instead:\n" <>
               Enum.join(offenders, "\n")
    end
  end

  # A typespec names the snooze tuple without building one, including on the
  # continuation line of a wrapped @spec.
  defp snooze_tuple?(line) do
    trimmed = String.trim_leading(line)

    String.contains?(line, "{:snooze,") and not String.starts_with?(trimmed, ["@spec", "#", "|"]) and
      not Regex.match?(~r/\{:snooze,\s*(pos_|non_neg_)?integer\(\)\}/, line)
  end
end
