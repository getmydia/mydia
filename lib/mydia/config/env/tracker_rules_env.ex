defmodule Mydia.Config.Env.TrackerRulesEnv do
  @moduledoc """
  Reads the `tracker_rules` list of `Mydia.Config.Schema` from
  `TRACKER_RULE_<N>_TRACKER`, `_SEED_RATIO`, `_SEED_TIME` (minutes),
  `_PRIVATE`, `_GRAB_LIMIT` and `_QUERY_LIMIT` (per rolling 24 hours).

  Values are passed through as strings and cast by the schema, so a typo such
  as `TRACKER_RULE_1_SEED_RATIO=one` is a config error rather than a silently
  dropped override (see `lib/mydia/config/README.md`). Any variable with the
  prefix declares its index, so a rule missing `_TRACKER` is rejected too.
  """

  alias Mydia.Config.Loader

  @prefix "TRACKER_RULE_"
  @fields [
    tracker: "TRACKER",
    seed_ratio: "SEED_RATIO",
    seed_time: "SEED_TIME",
    private: "PRIVATE",
    grab_limit: "GRAB_LIMIT",
    query_limit: "QUERY_LIMIT"
  ]

  @spec load() :: [map()]
  def load do
    System.get_env()
    |> Map.keys()
    |> Enum.flat_map(&index/1)
    |> Enum.uniq()
    |> Enum.sort_by(&sort_key/1)
    |> Enum.map(&rule/1)
    |> Enum.reject(&(&1 == %{}))
  end

  defp index(@prefix <> rest) do
    case Enum.find(@fields, fn {_field, suffix} -> String.ends_with?(rest, "_" <> suffix) end) do
      {_field, suffix} -> [String.replace_suffix(rest, "_" <> suffix, "")]
      nil -> []
    end
  end

  defp index(_key), do: []

  defp sort_key(index) do
    case Integer.parse(index) do
      {n, ""} -> {0, n, index}
      _ -> {1, 0, index}
    end
  end

  defp rule(index) do
    Enum.reduce(@fields, %{}, fn {field, suffix}, acc ->
      Loader.put_if_present(acc, field, System.get_env("#{@prefix}#{index}_#{suffix}"))
    end)
  end
end
