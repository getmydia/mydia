defmodule Mydia.TimeDisplay do
  @moduledoc """
  The time zone and clock the web UI renders timestamps in.

  The zone is the user's `time_zone` preference when it is set and still known
  to tzdata, otherwise the instance zone from the `TZ` env var, otherwise UTC.
  The clock is the user's `clock_format` preference; `"auto"` gives a 12-hour
  clock for English and a 24-hour clock for every other interface language.
  """

  require Logger

  alias Mydia.Accounts.UserPreference

  defstruct time_zone: "Etc/UTC", clock: :h24

  @type t :: %__MODULE__{time_zone: String.t(), clock: :h12 | :h24}

  @persistent_key {__MODULE__, :instance_time_zone}

  @doc """
  Validates a zone name against tzdata. Strips one leading `:` (glibc's
  `TZ=:Europe/Rome` form). POSIX rule strings are not IANA names and fail.
  """
  @spec parse_time_zone(String.t() | nil) :: {:ok, String.t()} | :error
  def parse_time_zone(value) when is_binary(value) do
    zone = value |> String.trim() |> String.trim_leading(":")

    if zone != "" and Tzdata.zone_exists?(zone), do: {:ok, zone}, else: :error
  end

  def parse_time_zone(_), do: :error

  @doc """
  The instance default zone from `TZ`, read once and cached. An unusable
  non-empty `TZ` logs one warning and falls back to UTC.
  """
  @spec instance_time_zone() :: String.t()
  def instance_time_zone do
    case :persistent_term.get(@persistent_key, nil) do
      nil ->
        zone = zone_from_env(System.get_env("TZ"))
        :persistent_term.put(@persistent_key, zone)
        zone

      zone ->
        zone
    end
  end

  defp zone_from_env(value) do
    case parse_time_zone(value) do
      {:ok, zone} ->
        zone

      :error ->
        if is_binary(value) and String.trim(value) != "" do
          Logger.warning(
            "TZ=#{inspect(value)} is not an IANA time zone name; showing times in UTC"
          )
        end

        "Etc/UTC"
    end
  end

  @doc "Resolves the display settings for a user (nil when signed out)."
  @spec for_user(UserPreference.t() | nil) :: t()
  def for_user(pref), do: resolve(pref, instance_time_zone())

  @doc "Pure form of `for_user/1`, with the instance zone passed in."
  @spec resolve(UserPreference.t() | nil, String.t()) :: t()
  def resolve(%UserPreference{} = pref, instance_zone) do
    zone =
      case parse_time_zone(UserPreference.time_zone(pref)) do
        {:ok, zone} -> zone
        :error -> instance_zone
      end

    %__MODULE__{time_zone: zone, clock: clock(pref)}
  end

  def resolve(nil, instance_zone), do: %__MODULE__{time_zone: instance_zone, clock: :h12}

  defp clock(pref) do
    case UserPreference.clock_format(pref) do
      "12" -> :h12
      "24" -> :h24
      _ -> if UserPreference.interface_language(pref) == "en", do: :h12, else: :h24
    end
  end
end
