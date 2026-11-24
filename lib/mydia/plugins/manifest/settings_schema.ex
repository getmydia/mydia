defmodule Mydia.Plugins.Manifest.SettingsSchema do
  @moduledoc """
  Validates a manifest's `settings_schema`: each field's key, type and
  type-specific options, unique keys, and `visible_when` references.

  `Mydia.Plugins.Manifest.parse/1` calls `validate/1`. The plugin-level checks
  on an `events` field, which need the subscribed events and `multi_instance`,
  live in `Mydia.Plugins.Manifest.EventField`.
  """

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Manifest.EventField

  # Field types a `settings_schema` entry may declare. `text` renders as a
  # multiline textarea (used for template fields); otherwise like `string`.
  @setting_types ~w(string url secret enum text events)

  @doc "Validates a `settings_schema`, defaulting a missing one to `[]`."
  @spec validate(term()) :: {:ok, [map()]} | {:error, Error.t()}
  def validate(nil), do: {:ok, []}

  def validate(schema) when not is_list(schema),
    do: {:error, Error.new(:invalid_manifest, "settings_schema must be a list")}

  def validate(schema) do
    with :ok <- validate_each_setting(schema),
         :ok <- validate_unique_setting_keys(schema),
         :ok <- validate_visible_when_keys(schema) do
      {:ok, schema}
    end
  end

  defp validate_each_setting(schema) do
    Enum.reduce_while(schema, :ok, fn field, :ok ->
      case validate_setting_field(field) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_setting_field(field) when not is_map(field),
    do: {:error, Error.new(:invalid_manifest, "settings_schema field must be an object")}

  # The checks run in a fixed order so a field with several problems always
  # reports the same first one.
  defp validate_setting_field(field) do
    key = Map.get(field, "key")
    type = Map.get(field, "type")

    with :ok <- validate_key_and_type(key, type),
         :ok <- validate_url_flags(field, key, type),
         :ok <- validate_enum_options(field, key, type),
         :ok <- validate_display(field, key) do
      EventField.validate_field(field, key, type)
    end
  end

  defp validate_key_and_type(key, type) do
    cond do
      blank?(key) ->
        {:error, Error.new(:invalid_manifest, "settings_schema field key is blank")}

      type not in @setting_types ->
        {:error,
         Error.new(:invalid_manifest, "settings_schema field #{key} has unknown type: #{type}")}

      true ->
        :ok
    end
  end

  defp validate_url_flags(field, key, type) do
    cond do
      Map.get(field, "grants_host") == true and type != "url" ->
        {:error,
         Error.new(:invalid_manifest, "grants_host is only allowed on url fields: #{key}")}

      Map.get(field, "allow_private") == true and
          not (type == "url" and Map.get(field, "grants_host") == true) ->
        {:error,
         Error.new(
           :invalid_manifest,
           "allow_private is only allowed on url fields with grants_host: #{key}"
         )}

      true ->
        :ok
    end
  end

  defp validate_enum_options(field, key, "enum") do
    if valid_options?(Map.get(field, "options")) do
      :ok
    else
      {:error,
       Error.new(
         :invalid_manifest,
         "enum setting #{key} must declare a non-empty options list"
       )}
    end
  end

  defp validate_enum_options(_field, _key, _type), do: :ok

  defp validate_display(field, key) do
    cond do
      not valid_visible_when?(Map.get(field, "visible_when")) ->
        {:error,
         Error.new(
           :invalid_manifest,
           "visible_when on #{key} must be an object mapping a setting key to a string or list of strings"
         )}

      not valid_hint?(Map.get(field, "hint")) ->
        {:error, Error.new(:invalid_manifest, "hint on #{key} must be a non-empty string")}

      true ->
        :ok
    end
  end

  # `hint` (optional) is help text the settings UI shows under the field.
  defp valid_hint?(nil), do: true
  defp valid_hint?(hint) when is_binary(hint), do: not blank?(hint)
  defp valid_hint?(_), do: false

  # `visible_when` (optional) gates a field's visibility in the settings UI on
  # the value of another setting: a map of `controlling_key => value`, where
  # value is a string or a non-empty list of strings. Absent means always shown.
  defp valid_visible_when?(nil), do: true

  defp valid_visible_when?(map) when is_map(map) and map_size(map) > 0 do
    Enum.all?(map, fn
      {k, v} when is_binary(k) -> valid_visible_when_value?(v)
      _ -> false
    end)
  end

  defp valid_visible_when?(_), do: false

  defp valid_visible_when_value?(v) when is_binary(v), do: true

  defp valid_visible_when_value?(v) when is_list(v) and v != [],
    do: Enum.all?(v, &is_binary/1)

  defp valid_visible_when_value?(_), do: false

  defp valid_options?(options) when is_list(options) and options != [],
    do: Enum.all?(options, &(is_binary(&1) and not blank?(&1)))

  defp valid_options?(_), do: false

  defp validate_unique_setting_keys(schema) do
    keys = Enum.map(schema, &Map.get(&1, "key"))

    if length(Enum.uniq(keys)) == length(keys) do
      :ok
    else
      {:error, Error.new(:invalid_manifest, "settings_schema keys must be unique")}
    end
  end

  # Every key referenced by a `visible_when` must name a sibling field, so the
  # UI can resolve the controlling value. (Shape is checked per-field above.)
  defp validate_visible_when_keys(schema) do
    keys = MapSet.new(schema, &Map.get(&1, "key"))

    schema
    |> Enum.flat_map(fn field ->
      case Map.get(field, "visible_when") do
        m when is_map(m) -> Map.keys(m)
        _ -> []
      end
    end)
    |> Enum.find(&(&1 not in keys))
    |> case do
      nil ->
        :ok

      missing ->
        {:error,
         Error.new(:invalid_manifest, "visible_when references unknown setting key: #{missing}")}
    end
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
