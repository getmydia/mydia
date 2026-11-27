defmodule MydiaWeb.AdminSettingsLive.SmartSpaceSettings do
  @moduledoc """
  What the Smart Space card of Admin Settings shows, and what saving it
  writes.

  The keys live in `Mydia.Config.Schema.SmartSpace` under the `smart_space`
  section. Rows are stored with the `:general` category, the same way the
  config layers resolve them by key rather than by category.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Accounts
  alias Mydia.Config.Schema.SmartSpace
  alias Mydia.Settings

  @env_vars %{
    "smart_space.enabled" => "SMART_SPACE_ENABLED",
    "smart_space.unit" => "SMART_SPACE_UNIT",
    "smart_space.grace_days" => "SMART_SPACE_GRACE_DAYS",
    "smart_space.watched_by" => "SMART_SPACE_WATCHED_BY",
    "smart_space.selected_users" => "SMART_SPACE_SELECTED_USERS"
  }

  @type setting :: %{value: term(), source: :env | :database | :default}

  @doc "Each key's resolved value and the layer it came from."
  @spec current() :: %{String.t() => setting()}
  def current do
    config = Mydia.Config.get().smart_space || %SmartSpace{}
    db_settings = Settings.applied_config_settings_by_key()

    %{
      "smart_space.enabled" => config.enabled,
      "smart_space.unit" => config.unit,
      "smart_space.grace_days" => config.grace_days,
      "smart_space.watched_by" => config.watched_by,
      "smart_space.selected_users" => config.selected_users || []
    }
    |> Map.new(fn {key, value} ->
      {key, %{value: value, source: Settings.config_source(@env_vars[key], key, db_settings)}}
    end)
  end

  @doc "The usernames the selected-people chips offer."
  @spec usernames() :: [String.t()]
  def usernames do
    Accounts.list_users()
    |> Enum.map(& &1.username)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.sort()
  end

  @doc """
  Writes the keys the form changed. Keys locked by an environment variable or
  equal to their resolved value are skipped. A value that fails validation
  writes nothing at all. Returns the keys written.
  """
  @spec save(map(), binary() | nil) ::
          {:ok, [String.t()]} | {:error, :validation, String.t()} | {:error, String.t(), term()}
  def save(params, user_id) do
    settings = current()
    known = usernames()

    with {:ok, desired} <- desired(params, settings),
         :ok <- validate_users(desired, known) do
      desired
      |> Enum.reject(fn {key, value} ->
        settings[key].source == :env or same?(settings[key].value, value)
      end)
      |> write(user_id)
    end
  end

  # Only the fields that arrived, parsed to their typed value. A key locked by
  # the environment counts as its resolved value for the cross-field check.
  defp desired(params, settings) do
    with {:ok, parsed} <- parse_all(params) do
      current = Map.new(settings, fn {key, %{value: value}} -> {key, value} end)
      locked = for {key, %{source: :env}} <- settings, do: key
      resolved = current |> Map.merge(parsed) |> Map.merge(Map.take(current, locked))

      if resolved["smart_space.watched_by"] == "selected" and
           resolved["smart_space.selected_users"] == [] do
        {:error, :validation, gettext("Pick at least one person, or choose a different rule.")}
      else
        {:ok, parsed}
      end
    end
  end

  defp parse_all(params) do
    [
      parse_enabled(params["enabled"]),
      parse_enum("smart_space.unit", params["unit"], SmartSpace.units()),
      parse_grace(params["grace_days"]),
      parse_enum("smart_space.watched_by", params["watched_by"], SmartSpace.watched_by_values()),
      parse_users(params)
    ]
    |> Enum.reduce_while({:ok, %{}}, fn
      :skip, {:ok, acc} -> {:cont, {:ok, acc}}
      {:ok, key, value}, {:ok, acc} -> {:cont, {:ok, Map.put(acc, key, value)}}
      {:error, :validation, _} = error, _acc -> {:halt, error}
    end)
  end

  defp parse_enabled(flag) when flag in ["true", "false"],
    do: {:ok, "smart_space.enabled", flag == "true"}

  defp parse_enabled(_), do: :skip

  defp parse_enum(key, value, allowed) when is_binary(value) do
    if value in allowed, do: {:ok, key, value}, else: {:error, :validation, invalid(key)}
  end

  defp parse_enum(_key, _value, _allowed), do: :skip

  defp parse_grace(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {days, ""} when days >= 0 -> {:ok, "smart_space.grace_days", days}
      _ -> {:error, :validation, invalid("smart_space.grace_days")}
    end
  end

  defp parse_grace(_), do: :skip

  # The chips submit only when the form carries the user group at all; a
  # present-but-empty group is a hidden "" marker, meaning nobody is selected.
  defp parse_users(%{"selected_users" => users}) when is_list(users),
    do: {:ok, "smart_space.selected_users", users |> Enum.reject(&(&1 == "")) |> Enum.uniq()}

  defp parse_users(_), do: :skip

  defp invalid(key),
    do: gettext("Invalid value for %{key}", key: key)

  defp validate_users(desired, known) do
    unknown = Enum.reject(Map.get(desired, "smart_space.selected_users", []), &(&1 in known))

    if unknown == [] do
      :ok
    else
      {:error, :validation, gettext("Unknown user: %{names}", names: Enum.join(unknown, ", "))}
    end
  end

  defp same?(current, value) when is_list(current) and is_list(value),
    do: Enum.sort(current) == Enum.sort(value)

  defp same?(current, value), do: current == value

  defp write(changes, user_id) do
    fn ->
      Enum.reduce(changes, [], fn {key, value}, written ->
        attrs = %{key: key, value: encode(value), category: :general, updated_by_id: user_id}

        case Settings.upsert_config_setting(attrs) do
          {:ok, _setting} -> [key | written]
          {:error, reason} -> Mydia.Repo.rollback({key, reason})
        end
      end)
    end
    |> Mydia.Repo.transaction()
    |> case do
      {:ok, written} -> {:ok, written}
      {:error, {key, reason}} -> {:error, key, reason}
    end
  end

  defp encode(list) when is_list(list), do: Enum.join(list, ",")
  defp encode(value), do: to_string(value)
end
