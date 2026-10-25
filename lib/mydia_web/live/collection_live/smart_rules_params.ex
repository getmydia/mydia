defmodule MydiaWeb.CollectionLive.SmartRulesParams do
  @moduledoc """
  Builds the smart collection rules JSON from the edit form's params.
  """

  import MydiaWeb.CollectionLive.Components, only: [value_list: 1]

  @doc "Encodes the form params as the smart rules JSON stored on the collection."
  def build_json(params) do
    match_type = params["match_type"] || "all"
    sort_field = params["sort_field"] || ""
    sort_direction = params["sort_direction"] || "desc"

    %{
      "match_type" => match_type,
      "conditions" => build_conditions(params)
    }
    |> put_sort(sort_field, sort_direction)
    |> put_limit(parse_limit(params["limit"]))
    |> Jason.encode!()
  end

  # Get conditions from params
  defp build_conditions(params) do
    case params["conditions"] do
      nil ->
        []

      cond_params when is_map(cond_params) ->
        cond_params
        |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
        |> Enum.map(fn {_, cond} ->
          value = parse_condition_value(cond["field"], cond["value"], cond["operator"])

          %{
            "field" => cond["field"],
            "operator" => cond["operator"],
            "value" => value
          }
        end)
        |> Enum.filter(fn c -> c["field"] != "" end)
    end
  end

  defp parse_limit(nil), do: nil
  defp parse_limit(""), do: nil
  defp parse_limit(val) when is_binary(val), do: String.to_integer(val)
  defp parse_limit(val), do: val

  # Add sort if specified
  defp put_sort(rules, "", _direction), do: rules

  defp put_sort(rules, field, direction),
    do: Map.put(rules, "sort", %{"field" => field, "direction" => direction})

  # Add limit if specified
  defp put_limit(rules, limit) when is_number(limit) and limit > 0,
    do: Map.put(rules, "limit", limit)

  defp put_limit(rules, _limit), do: rules

  # Fields that should always keep string values
  @string_fields ~w(category type title metadata.original_language metadata.status)

  # Fields that should be parsed as numbers
  @numeric_fields ~w(year metadata.vote_average)

  defp parse_condition_value(_field, value, operator)
       when operator in ["in", "not_in", "contains_any"] do
    value_list(value)
  end

  # A multi-select's list can outlive a switch to a scalar operator by one change
  # event. The editor narrows that list to its first entry, so parse the same one
  # rather than a joined string, which would match nothing.
  defp parse_condition_value(field, value, operator) when is_list(value) do
    parse_condition_value(field, value |> value_list() |> List.first(""), operator)
  end

  defp parse_condition_value(_field, value, "between") do
    # Parse "min, max" into [min, max]
    case String.split(value, ",") do
      [min, max] ->
        [parse_number(String.trim(min)), parse_number(String.trim(max))]

      _ ->
        value
    end
  end

  # String fields should always remain as strings
  defp parse_condition_value(field, value, _operator) when field in @string_fields do
    value
  end

  # Numeric fields should be parsed as numbers
  defp parse_condition_value(field, value, _operator) when field in @numeric_fields do
    parse_number(value)
  end

  # For monitored (boolean field)
  defp parse_condition_value("monitored", value, _operator) do
    case String.downcase(String.trim(value)) do
      "true" -> true
      "false" -> false
      "1" -> true
      "0" -> false
      _ -> value
    end
  end

  # Default: try to parse as number, otherwise keep as string
  defp parse_condition_value(_field, value, _operator) do
    case Integer.parse(value) do
      {num, ""} -> num
      _ -> value
    end
  end

  defp parse_number(str) do
    case Integer.parse(str) do
      {num, ""} -> num
      _ -> str
    end
  end
end
