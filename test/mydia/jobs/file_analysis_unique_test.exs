defmodule Mydia.Jobs.FileAnalysisUniqueTest do
  use Mydia.DataCase, async: false

  alias Mydia.Jobs.FileAnalysis
  alias Mydia.Repo

  @name __MODULE__.Oban

  # The app disables Oban's engine in test (config/test.exs) to avoid pool
  # conflicts with the SQL Sandbox, but unique-job enforcement lives in the
  # engine — Oban.insert/2 can't detect a conflict against `engine: false`.
  # Start a dedicated, real-engine Oban instance for this test module,
  # selecting the engine the same way config/config.exs does, so this test
  # exercises actual uniqueness enforcement on both SQLite and PostgreSQL.
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

  test "a job in :retryable blocks a duplicate insert" do
    {:ok, first} = Oban.insert(@name, FileAnalysis.new(%{}))

    first
    |> Ecto.Changeset.change(state: "retryable")
    |> Repo.update!()

    {:ok, second} = Oban.insert(@name, FileAnalysis.new(%{}))

    assert second.conflict?,
           "a FileAnalysis job in :retryable must block a duplicate insert, " <>
             "otherwise a failed analysis run lets a second one start on the same files"
  end
end
