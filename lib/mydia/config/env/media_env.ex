defmodule Mydia.Config.Env.MediaEnv do
  @moduledoc """
  Reads the `media` section of `Mydia.Config.Schema` from the environment.
  """

  import Mydia.Config.Loader,
    only: [put_if_present: 3, put_if_present: 4, parse_boolean: 1, parse_integer: 1]

  @spec load() :: map()
  def load do
    %{}
    |> put_if_present(:movies_path, System.get_env("MOVIES_PATH"))
    |> put_if_present(:tv_path, System.get_env("TV_PATH"))
    |> put_if_present(
      :movies_auto_organize,
      System.get_env("MOVIES_AUTO_ORGANIZE"),
      &parse_boolean/1
    )
    |> put_if_present(:tv_auto_organize, System.get_env("TV_AUTO_ORGANIZE"), &parse_boolean/1)
    |> put_if_present(:auto_search_on_add, System.get_env("AUTO_SEARCH_ON_ADD"), &parse_boolean/1)
    |> put_if_present(:monitor_by_default, System.get_env("MONITOR_BY_DEFAULT"), &parse_boolean/1)
    |> put_if_present(
      :minimum_availability,
      System.get_env("MINIMUM_AVAILABILITY"),
      &{:ok, &1 |> String.trim() |> String.downcase()}
    )
    |> put_if_present(
      :default_season_monitoring,
      System.get_env("DEFAULT_SEASON_MONITORING"),
      &{:ok, String.downcase(&1)}
    )
    |> put_if_present(
      :trash_retention_days,
      System.get_env("TRASH_RETENTION_DAYS"),
      &parse_integer/1
    )
  end
end
