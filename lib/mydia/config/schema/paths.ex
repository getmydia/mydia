defmodule Mydia.Config.Schema.Paths do
  @moduledoc """
  The dotted keys a `config_settings` row may legally carry, and the type each
  one casts to.

  `config_settings` holds two populations of row, consumed by unrelated code.

  **Overlay rows** name a leaf of an `embeds_one` section of
  `Mydia.Config.Schema`, for example `server.port`.
  `Mydia.Settings.RuntimeConfig.build_config_map/1` merges these into the cached
  runtime config, between the YAML and environment layers.

  **Direct-lookup rows** are read by key through
  `Mydia.Settings.get_config_setting_by_key/1` and never reach that merge. They
  have no schema field, so the merge has always built them into its map and
  `Mydia.Config.Schema.changeset/2` has always dropped them again by ignoring
  the unknown key. Four of the five keys name a section the schema does not
  have at all, spread across three such sections: `crash_reporting`,
  `feedback`, and `library` (which contributes two keys). The fifth,
  `media.default_quality_profile_id`, names a section that does exist but
  bypasses the merge anyway. They are listed in `@direct_keys` with their
  reader, so the next person to add a `get_config_setting_by_key/1` call with
  a literal key finds the list.

  `database.*` is deliberately in neither. The database section is consumed to
  open the repo, before the database layer can be read, so such a row can never
  take effect.
  """

  alias Mydia.Config.Schema

  @excluded_sections [:database]

  # The environment variable that actually controls a key in an excluded
  # section, for the ones that map to one. `Mydia.Repo`'s real pool_size and
  # database_path come from these variables in config/runtime.exs, never from
  # a config_settings row, which is why :database is excluded from
  # @overlay_index below rather than folded into it.
  @excluded_key_env_vars %{
    "database.path" => "DATABASE_PATH",
    "database.pool_size" => "POOL_SIZE"
  }

  @direct_keys %{
    "crash_reporting.enabled" => "Mydia.CrashReporter",
    "feedback.enabled" => "Mydia.Feedback.enabled?/0",
    "library.auto_repair_enabled" => "Mydia.Library.DatabaseHealthCheck",
    "library.auto_repair_threshold" => "Mydia.Library.DatabaseHealthCheck",
    "media.default_quality_profile_id" => "Mydia.Settings.QualityProfiles"
  }

  # Built at compile time from the schema itself. A hand-maintained list drifts
  # from the schema and turns the write-side validation into a source of false
  # rejections, so this must stay derived.
  @overlay_index Schema.__schema__(:embeds)
                 |> Enum.reject(&(&1 in @excluded_sections))
                 |> Enum.flat_map(fn section ->
                   case Schema.__schema__(:embed, section) do
                     %Ecto.Embedded{cardinality: :one, related: related} ->
                       Enum.map(related.__schema__(:fields), fn field ->
                         {"#{section}.#{field}",
                          {[section, field], related.__schema__(:type, field)}}
                       end)

                     _ ->
                       []
                   end
                 end)
                 |> Map.new()

  # Every leaf of an excluded section, built the same way as @overlay_index
  # above. Used only so cast_overlay_key/2 can tell an operator "this cannot
  # be set from the database" apart from "this key does not exist"; never
  # accepted anywhere else.
  @excluded_index Schema.__schema__(:embeds)
                  |> Enum.filter(&(&1 in @excluded_sections))
                  |> Enum.flat_map(fn section ->
                    case Schema.__schema__(:embed, section) do
                      %Ecto.Embedded{cardinality: :one, related: related} ->
                        Enum.map(related.__schema__(:fields), &"#{section}.#{&1}")

                      _ ->
                        []
                    end
                  end)
                  |> MapSet.new()

  @doc "Every dotted key that maps to a leaf of an `embeds_one` schema section."
  @spec overlay_keys() :: [String.t()]
  def overlay_keys, do: Map.keys(@overlay_index)

  @doc "Every dotted key read directly by `get_config_setting_by_key/1`."
  @spec direct_keys() :: [String.t()]
  def direct_keys, do: Map.keys(@direct_keys)

  @doc "Whether a key belongs to either population."
  @spec known?(String.t()) :: boolean()
  def known?(key), do: Map.has_key?(@overlay_index, key) or Map.has_key?(@direct_keys, key)

  @doc "Whether a key is read directly rather than through the config merge."
  @spec direct?(String.t()) :: boolean()
  def direct?(key), do: Map.has_key?(@direct_keys, key)

  @doc """
  Resolves one row to the path and value it contributes to the merge.

  Returns `{:ok, path, value}` for an overlay row, `:direct` for a row that is
  read by key and contributes nothing, and `{:error, reason}` for a row that
  cannot be used at all. Never raises: the caller decides what a bad row means.
  """
  @spec cast_overlay(String.t(), String.t() | nil) ::
          {:ok, [atom()], term()} | :direct | {:error, String.t()}
  def cast_overlay(key, value) do
    if direct?(key) do
      :direct
    else
      cast_overlay_key(key, value)
    end
  end

  defp cast_overlay_key(key, value) do
    case Map.fetch(@overlay_index, key) do
      {:ok, {path, type}} ->
        case cast_value(type, value) do
          {:ok, casted} ->
            {:ok, path, casted}

          :error ->
            {:error, "#{key}: #{inspect(value)} is not a valid #{inspect(type)}"}
        end

      :error ->
        {:error, unknown_key_reason(key)}
    end
  end

  # A key outside @overlay_index is either a genuine typo or a real schema
  # field that was excluded on purpose. Telling those apart matters: an
  # operator who sees "unknown configuration key" for database.pool_size will
  # reasonably conclude they mistyped something, when the actionable fact is
  # that the row can never take effect and POOL_SIZE is the real knob.
  defp unknown_key_reason(key) do
    case Map.fetch(@excluded_key_env_vars, key) do
      {:ok, env_var} ->
        "#{key}: set via the #{env_var} environment variable, not the database"

      :error ->
        if MapSet.member?(@excluded_index, key) do
          "#{key}: cannot be set from the database; this section is read before the database layer exists"
        else
          "#{key}: unknown configuration key"
        end
    end
  end

  # An empty value means unset, which is how clearing a field in the admin UI
  # has always behaved, and how server.url_host records a cleared default.
  defp cast_value(_type, nil), do: {:ok, nil}
  defp cast_value(_type, ""), do: {:ok, nil}

  # Array fields arrive comma-separated, matching how the environment layer
  # parses the same fields.
  defp cast_value({:array, inner}, value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case Ecto.Type.cast(inner, part) do
        {:ok, casted} -> {:cont, {:ok, [casted | acc]}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      :error -> :error
    end
  end

  defp cast_value(type, value) do
    case Ecto.Type.cast(type, value) do
      {:ok, casted} -> {:ok, casted}
      _ -> :error
    end
  end
end
