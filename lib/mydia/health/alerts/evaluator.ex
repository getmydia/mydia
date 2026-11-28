defmodule Mydia.Health.Alerts.Evaluator do
  @moduledoc """
  Turns per-condition observations into a debounced list of alerts.

  A condition becomes an alert once it has been failing for
  `raise_after_seconds/0` (10 minutes), so restarts and brief reconnects stay
  quiet. It is dropped only after it has been clear for
  `clear_after_seconds/0` (5 minutes). A failure inside that clear window
  keeps the original start time, so a flapping outage counts as one
  continuous outage, both before and after the alert is raised.

  Pure: callers pass `now` and carry the returned state to the next call.
  """

  alias Mydia.Health.Alert

  @raise_after_seconds 600
  @clear_after_seconds 300

  @type observation :: %{title: String.t(), detail: String.t() | nil, fix_path: String.t()}
  @type observations :: %{term() => observation() | nil}
  @type entry :: %{
          first_failing_at: DateTime.t(),
          last_failing_at: DateTime.t(),
          last_observation: observation()
        }
  @type state :: %{term() => entry()}

  def raise_after_seconds, do: @raise_after_seconds
  def clear_after_seconds, do: @clear_after_seconds

  @doc """
  Folds `observations` into `state` at `now` and returns the alerts to show.

  A key missing from `observations` counts as clear.
  """
  @spec evaluate(observations(), state(), DateTime.t()) :: {[Alert.t()], state()}
  def evaluate(observations, state, now) do
    keys = Enum.uniq(Map.keys(state) ++ Map.keys(observations))

    state =
      Enum.reduce(keys, state, fn key, acc ->
        update_entry(acc, key, Map.get(observations, key), now)
      end)

    alerts =
      state
      |> Enum.filter(fn {_key, entry} ->
        DateTime.diff(now, entry.first_failing_at) >= @raise_after_seconds
      end)
      |> Enum.map(fn {key, entry} -> to_alert(key, entry) end)
      |> Enum.sort_by(&{DateTime.to_unix(&1.since, :microsecond), inspect(&1.key)})

    {alerts, state}
  end

  defp update_entry(state, key, nil, now) do
    case Map.fetch(state, key) do
      {:ok, entry} ->
        if DateTime.diff(now, entry.last_failing_at) >= @clear_after_seconds,
          do: Map.delete(state, key),
          else: state

      :error ->
        state
    end
  end

  defp update_entry(state, key, observation, now) do
    Map.update(
      state,
      key,
      %{first_failing_at: now, last_failing_at: now, last_observation: observation},
      &%{&1 | last_failing_at: now, last_observation: observation}
    )
  end

  defp to_alert(key, entry) do
    %Alert{
      key: key,
      title: entry.last_observation.title,
      detail: Map.get(entry.last_observation, :detail),
      fix_path: entry.last_observation.fix_path,
      since: entry.first_failing_at
    }
  end
end
