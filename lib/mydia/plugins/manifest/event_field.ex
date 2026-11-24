defmodule Mydia.Plugins.Manifest.EventField do
  @moduledoc """
  The `events` settings field: the manifest checks for it and its lookup.

  An `events` setting lets each instance choose which of the plugin's
  subscribed events it receives. `validate_field/3` checks one field's shape,
  `validate/3` checks the field against the whole plugin, and `field/1` reads
  it back for `Mydia.Plugins.EventSelection`.
  """

  alias Mydia.Plugins.Error

  @doc "Checks an `events` field's own shape: `default` is a list of event names."
  @spec validate_field(map(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def validate_field(field, key, "events") do
    if valid_events_default?(Map.get(field, "default")) do
      :ok
    else
      {:error,
       Error.new(
         :invalid_manifest,
         "default on events setting #{key} must be a list of event names"
       )}
    end
  end

  def validate_field(_field, _key, _type), do: :ok

  defp valid_events_default?(nil), do: true
  defp valid_events_default?(list) when is_list(list), do: Enum.all?(list, &is_binary/1)
  defp valid_events_default?(_), do: false

  @doc """
  Checks the `events` field against the plugin. It needs the plugin-level event
  list to check `default` against, and is meaningless on a multi_instance
  plugin, so these checks run after both are known.
  """
  @spec validate([map()], [String.t()], boolean()) :: :ok | {:error, Error.t()}
  def validate(schema, events, multi_instance) do
    fields = Enum.filter(schema, &(Map.get(&1, "type") == "events"))

    cond do
      fields == [] ->
        :ok

      length(fields) > 1 ->
        {:error,
         Error.new(:invalid_manifest, "settings_schema may declare at most one events field")}

      multi_instance ->
        {:error,
         Error.new(:invalid_manifest, "an events field is not allowed on a multi_instance plugin")}

      true ->
        [field] = fields
        extra = List.wrap(Map.get(field, "default")) -- events

        if extra == [] do
          :ok
        else
          {:error,
           Error.new(
             :invalid_manifest,
             "default on events setting #{field["key"]} names events the plugin does not subscribe to: #{Enum.join(extra, ", ")}"
           )}
        end
    end
  end

  @doc """
  The `events` field of a settings schema as `%{key: key, default: default}`, or
  `nil` when it declares none. `default` is `nil` when the field omits it.
  """
  @spec field([map()]) :: %{key: String.t(), default: [String.t()] | nil} | nil
  def field(schema) when is_list(schema) do
    case Enum.find(schema, &(is_map(&1) and Map.get(&1, "type") == "events")) do
      nil -> nil
      field -> %{key: field["key"], default: Map.get(field, "default")}
    end
  end

  def field(_), do: nil
end
