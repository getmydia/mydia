defmodule Mydia.Repo.MediaFilesTrashedAtIndexTest do
  @moduledoc """
  Locks in the query plan for the episode `media_files` preload.

  `Episode.media_files` is a many_to_many through `media_file_episodes`, and the
  preload filters `trashed_at IS NULL`. SQLite has no `sqlite_stat1` on these
  installs, so an index over `trashed_at` looked selective to its planner even
  though nearly every row is untrashed. It drove the join from that index and
  probed `media_file_episodes` once per episode id per file: 1.8 seconds for
  3,773 episodes on a real library, which made `/tv` take over three seconds.
  """
  use Mydia.DataCase

  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode

  # Enough ids that the IN list is realistic for a library's worth of episodes.
  @episode_count 800

  def handle_query(_event, _measurements, metadata, %{pid: pid}) do
    send(pid, {:query, metadata.query, metadata.params})
  end

  describe "SQLite query plans" do
    test "the episode media_files preload does not drive from the trashed_at index" do
      if Mydia.DB.sqlite?() do
        episodes = for _ <- 1..@episode_count, do: %Episode{id: Ecto.UUID.generate()}

        {sql, params} =
          capture_query("media_file_episodes", fn ->
            Repo.preload(episodes, media_files: MediaFile.versions())
          end)

        plan = query_plan(sql, params)

        refute Enum.any?(plan, &String.contains?(&1, "media_files_trashed_at_index")),
               "preload drives from media_files_trashed_at_index:\n#{Enum.join(plan, "\n")}"

        assert Enum.any?(plan, &String.contains?(&1, "media_file_episodes_episode_id_index")),
               "preload does not look episodes up by id:\n#{Enum.join(plan, "\n")}"
      else
        assert Mydia.DB.postgres?()
      end
    end

    test "trash queries still use the trashed_at index" do
      if Mydia.DB.sqlite?() do
        query =
          from f in MediaFile,
            where: not is_nil(f.trashed_at),
            order_by: [desc: f.trashed_at, desc: f.id]

        {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)
        plan = query_plan(sql, params)

        assert Enum.any?(plan, &String.contains?(&1, "media_files_trashed_at_index")),
               "trash listing no longer uses the index:\n#{Enum.join(plan, "\n")}"
      else
        assert Mydia.DB.postgres?()
      end
    end
  end

  test "the trashed_at index covers only trashed rows" do
    definition =
      if Mydia.DB.sqlite?() do
        sql!("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = $1")
      else
        sql!("SELECT indexdef FROM pg_indexes WHERE indexname = $1")
      end

    # SQLite keeps the text as written, NOT (trashed_at IS NULL); PostgreSQL
    # normalises it to (trashed_at IS NOT NULL).
    assert definition =~
             ~r/WHERE\s*\(?\s*(NOT\s*\(\s*"?trashed_at"?\s+IS NULL\s*\)|"?trashed_at"?\s+IS NOT NULL)/i
  end

  defp sql!(statement) do
    %{rows: [[definition]]} = Repo.query!(statement, ["media_files_trashed_at_index"])
    definition
  end

  defp capture_query(fragment, fun) do
    handler_id = "media-files-trashed-at-index-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(handler_id, [:mydia, :repo, :query], &__MODULE__.handle_query/4, %{
      pid: self()
    })

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    receive_query(fragment)
  end

  defp receive_query(fragment) do
    receive do
      {:query, sql, params} ->
        if String.contains?(sql, fragment), do: {sql, params}, else: receive_query(fragment)
    after
      0 -> flunk("no query mentioning #{fragment} was issued")
    end
  end

  defp query_plan(sql, params) do
    %{rows: rows} = Repo.query!("EXPLAIN QUERY PLAN " <> sql, params)
    Enum.map(rows, &List.last/1)
  end
end
