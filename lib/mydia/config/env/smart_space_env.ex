defmodule Mydia.Config.Env.SmartSpaceEnv do
  @moduledoc """
  Reads the `smart_space` section of `Mydia.Config.Schema` from the
  environment (`SMART_SPACE_ENABLED`, `SMART_SPACE_UNIT`,
  `SMART_SPACE_GRACE_DAYS`, `SMART_SPACE_WATCHED_BY`,
  `SMART_SPACE_SELECTED_USERS`).

  Enum values go through a fixed-value parser that maps unknown strings to
  `:invalid`, so a typo fails validation by name instead of silently falling
  back to the default. `Loader.parse_atom/1` must not be used here. The
  boolean (trimmed, any case) and the integer (trimmed) get the same
  treatment: a present value that does
  not parse becomes `:invalid`, which does not cast, so `SMART_SPACE_ENABLED=yes`
  or `SMART_SPACE_GRACE_DAYS=7d` stops startup instead of being dropped. See
  `lib/mydia/config/README.md`.
  """

  import Mydia.Config.Loader,
    only: [put_if_present: 4, parse_boolean: 1, parse_integer: 1]

  alias Mydia.Config.Schema.SmartSpace

  @spec load((String.t() -> String.t() | nil)) :: map()
  def load(getenv \\ &System.get_env/1) do
    %{}
    |> put_if_present(:enabled, getenv.("SMART_SPACE_ENABLED"), &or_invalid(&1, :boolean))
    |> put_if_present(:unit, getenv.("SMART_SPACE_UNIT"), &parse_enum(&1, SmartSpace.units()))
    |> put_if_present(
      :grace_days,
      getenv.("SMART_SPACE_GRACE_DAYS"),
      &or_invalid(&1, :integer)
    )
    |> put_if_present(
      :watched_by,
      getenv.("SMART_SPACE_WATCHED_BY"),
      &parse_enum(&1, SmartSpace.watched_by_values())
    )
    |> put_if_present(
      :selected_users,
      getenv.("SMART_SPACE_SELECTED_USERS"),
      &parse_users/1
    )
  end

  defp or_invalid(value, type) do
    trimmed = String.trim(value)

    parsed =
      if type == :boolean,
        do: parse_boolean(String.downcase(trimmed)),
        else: parse_integer(trimmed)

    case parsed do
      {:ok, _} = ok -> ok
      :error -> {:ok, :invalid}
    end
  end

  defp parse_enum(value, allowed) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in allowed, do: {:ok, normalized}, else: {:ok, :invalid}
  end

  defp parse_users(value) do
    {:ok,
     value
     |> String.split(",")
     |> Enum.map(&String.trim/1)
     |> Enum.reject(&(&1 == ""))}
  end
end
