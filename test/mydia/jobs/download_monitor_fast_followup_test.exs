defmodule Mydia.Jobs.DownloadMonitorFastFollowupTest do
  use Mydia.DataCase, async: false

  alias Mydia.Jobs.DownloadMonitor
  alias Mydia.Repo

  @name __MODULE__.Oban

  # DownloadMonitor's unique config uses the `:incomplete` state group, which
  # includes :executing. That's only safe for the self-reinserting
  # fast-followup chain (see `maybe_schedule_fast_followup/2`) because
  # uniqueness is keyed on the default `[:args, :queue, :worker]` fields, and
  # a followup's `"fast_chain_position"` arg never matches its parent's args.
  # As with FileAnalysisUniqueTest, uniqueness enforcement lives in the
  # engine, and the app disables it in test (config/test.exs) to avoid pool
  # conflicts with the SQL Sandbox — so this needs its own real-engine Oban
  # instance, adapter-selected the same way config/config.exs is.
  setup do
    engine =
      case Repo.__adapter__() do
        Ecto.Adapters.Postgres -> Oban.Engines.Basic
        _ -> Oban.Engines.Lite
      end

    start_supervised!(
      {Oban,
       name: @name, repo: Repo, engine: engine, testing: :manual, queues: false, plugins: false}
    )

    :ok
  end

  test "a fast-followup insert is not a conflict with its still-executing parent" do
    {:ok, parent} = Oban.insert(@name, DownloadMonitor.new(%{}))

    parent
    |> Ecto.Changeset.change(state: "executing")
    |> Repo.update!()

    {:ok, followup} =
      Oban.insert(@name, DownloadMonitor.new(%{"fast_chain_position" => 1}))

    refute followup.conflict?,
           "a fast-followup insert must not be deduped against its own still-executing " <>
             "parent, otherwise the adaptive polling chain silently stops advancing"
  end
end
