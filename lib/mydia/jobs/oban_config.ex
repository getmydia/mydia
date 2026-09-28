defmodule Mydia.Jobs.ObanConfig do
  @moduledoc """
  Overlays runtime Oban settings (poll_interval, max_age_days) onto the base
  Oban supervisor configuration.
  """

  alias Mydia.Config.Schema.Oban, as: ObanSchema

  @doc """
  Applies `poll_interval` and `max_age_days` from `oban_runtime_config` to `base_config`.
  """
  @spec apply_runtime_config(keyword(), ObanSchema.t() | nil) :: keyword()
  def apply_runtime_config(base_config, nil), do: base_config

  def apply_runtime_config(base_config, %ObanSchema{} = runtime) do
    base_config
    |> apply_poll_interval(runtime.poll_interval)
    |> apply_max_age_days(runtime.max_age_days)
  end

  defp apply_poll_interval(config, interval) when is_integer(interval) and interval > 0 do
    Keyword.put(config, :stage_interval, interval)
  end

  defp apply_poll_interval(config, _), do: config

  defp apply_max_age_days(config, days) when is_integer(days) and days > 0 do
    max_age_seconds = days * 86_400
    plugins = Keyword.get(config, :plugins, [])

    updated_plugins =
      Enum.map(plugins, fn
        {Oban.Plugins.Pruner, opts} when is_list(opts) ->
          {Oban.Plugins.Pruner, Keyword.put(opts, :max_age, max_age_seconds)}

        Oban.Plugins.Pruner ->
          {Oban.Plugins.Pruner, [max_age: max_age_seconds]}

        {Oban.Pruner, opts} when is_list(opts) ->
          {Oban.Pruner, Keyword.put(opts, :max_age, max_age_seconds)}

        Oban.Pruner ->
          {Oban.Pruner, [max_age: max_age_seconds]}

        other ->
          other
      end)

    Keyword.put(config, :plugins, updated_plugins)
  end

  defp apply_max_age_days(config, _), do: config
end
