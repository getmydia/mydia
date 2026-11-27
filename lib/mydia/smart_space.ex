defmodule Mydia.SmartSpace do
  @moduledoc """
  Smart Space: trashes TV that every required viewer has finished.

  `upcoming/1` previews what will become eligible; `run/1` does the work.
  Eligibility lives in `Mydia.SmartSpace.Evaluator` (pure) fed by
  `Mydia.SmartSpace.Loader`. This module only applies the verdicts: it moves
  files to the trash with `reason: :smart_space`, unmonitors the episodes whose
  files all moved, and records events. It never deletes anything.

  A season that was due is listed with every episode, including episodes
  without files, so unmonitoring covers the whole season. An episode that owns
  a file that failed to trash stays monitored, and the next run retries it.
  """

  import Ecto.Query

  require Logger

  alias Mydia.Events
  alias Mydia.Library
  alias Mydia.Media.Episode
  alias Mydia.Media.Monitoring
  alias Mydia.Repo
  alias Mydia.SmartSpace.{Cleanup, Evaluator, Loader}

  @default_cap 200
  @default_within_days 30
  @run_types ["smart_space.run", "smart_space.cleanup"]

  @type summary :: %{
          cleanups: non_neg_integer(),
          files: non_neg_integer(),
          failed: non_neg_integer(),
          bytes: non_neg_integer(),
          capped?: boolean()
        }

  @doc """
  Cleanups that will be eligible within `opts[:within_days]` (default 30),
  with `eligible_at` set. Narrow to one show with `opts[:media_item_id]`.
  """
  @spec upcoming(keyword()) :: [Cleanup.t()]
  def upcoming(opts \\ []) do
    within = Keyword.get(opts, :within_days, @default_within_days)
    at = DateTime.add(Keyword.get_lazy(opts, :now, &DateTime.utc_now/0), within, :day)

    opts
    |> Keyword.take([:media_item_id, :config])
    |> Loader.load()
    |> evaluate(at)
  end

  @doc """
  Trashes everything eligible now, up to `opts[:cap]` files (default 200).

  Returns `{:error, :misconfigured}` (and records a warning event) when the
  `selected` policy names users that do not exist.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, :misconfigured}
  def run(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    cap = Keyword.get(opts, :cap, @default_cap)
    inputs = opts |> Keyword.take([:config]) |> Loader.load()

    cond do
      inputs.selected_user_ids == :misconfigured ->
        record(%{type: "smart_space.misconfigured", severity: :warning, metadata: %{}})
        {:error, :misconfigured}

      inputs.shows == [] ->
        {:ok, empty_summary()}

      true ->
        {chosen, capped?} = inputs |> evaluate(now) |> apply_cap(cap)
        summary = Enum.reduce(chosen, %{empty_summary() | capped?: capped?}, &apply_cleanup/2)

        record(%{
          type: "smart_space.run",
          metadata: Map.new(Map.delete(summary, :capped?)) |> Map.put(:capped, capped?)
        })

        {:ok, summary}
    end
  end

  @doc "When Smart Space last ran or trashed something, or `nil`."
  @spec last_run_at() :: DateTime.t() | nil
  def last_run_at do
    Repo.one(
      from e in Mydia.Events.Event,
        where: e.type in ^@run_types,
        select: max(e.inserted_at)
    )
  end

  defp evaluate(inputs, now), do: Evaluator.eligible(inputs, now, DateTime.to_date(now))

  defp empty_summary, do: %{cleanups: 0, files: 0, failed: 0, bytes: 0, capped?: false}

  # Cleanups arrive sorted by eligible_at. One that does not fit in what is
  # left of the cap is skipped, never split; later, smaller ones may still fit.
  defp apply_cap(cleanups, cap) do
    {chosen, _total, capped?} =
      Enum.reduce(cleanups, {[], 0, false}, fn cleanup, {acc, total, capped?} ->
        count = length(cleanup.file_ids)

        cond do
          total + count <= cap ->
            {[cleanup | acc], total + count, capped?}

          true ->
            if count > cap do
              Logger.warning("Smart Space skipped a cleanup larger than the cap",
                media_item_id: cleanup.media_item_id,
                season_number: cleanup.season_number,
                files: count,
                cap: cap
              )
            end

            {acc, total, true}
        end
      end)

    {Enum.reverse(chosen), capped?}
  end

  defp apply_cleanup(%Cleanup{} = cleanup, summary) do
    {:ok, %{trashed: trashed, failed: failed, bytes: bytes}} =
      Library.trash_episode_files(cleanup.episode_ids, reason: :smart_space)

    failed_episode_ids = MapSet.new(failed, fn {file, _reason} -> file.episode_id end)
    done_ids = Enum.reject(cleanup.episode_ids, &MapSet.member?(failed_episode_ids, &1))

    Monitoring.set_episodes_monitored(
      Repo.all(from e in Episode, where: e.id in ^done_ids),
      false
    )

    if trashed != [] do
      record(%{
        type: "smart_space.cleanup",
        resource_type: "media_item",
        resource_id: cleanup.media_item_id,
        metadata: %{
          season_number: cleanup.season_number,
          episode_count: length(cleanup.episode_ids),
          file_count: length(trashed),
          bytes: bytes
        }
      })
    end

    %{
      summary
      | cleanups: summary.cleanups + if(trashed != [], do: 1, else: 0),
        files: summary.files + length(trashed),
        failed: summary.failed + length(failed),
        bytes: summary.bytes + bytes
    }
  end

  defp record(attrs) do
    base = %{
      category: "media",
      actor_type: :job,
      actor_id: "smart_space",
      severity: :info
    }

    case Events.create_event(Map.merge(base, attrs)) do
      {:ok, _} -> :ok
      {:error, cs} -> Logger.warning("Smart Space event not recorded", errors: inspect(cs.errors))
    end
  end
end
