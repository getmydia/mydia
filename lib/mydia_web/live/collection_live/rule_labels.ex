defmodule MydiaWeb.CollectionLive.RuleLabels do
  @moduledoc """
  Translated text for smart collection rules.

  `Mydia.Collections.SmartRulesFields` and `Mydia.Collections.SmartRules` keep
  the English labels and validation sentences and never depend on Gettext. The
  web layer translates by key: a known value option gets a msgid, a known
  validation error becomes a whole sentence with bindings, and anything else
  passes through unchanged.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Media.MediaCategory
  alias MydiaWeb.StatusLabels

  @doc """
  Translates the label of one `{value, label}` option of an enum or boolean
  field. Options without a fixed vocabulary (genres, languages, statuses) keep
  the label the domain gives them, since those are data.
  """
  @spec value_option(String.t(), {term(), String.t()}) :: {term(), String.t()}
  def value_option(field, {value, label}),
    do: {value, value_label(field, to_string(value), label)}

  defp value_label("type", "movie", _label), do: gettext("Movie")
  defp value_label("type", "tv_show", _label), do: gettext("TV Show")

  defp value_label("category", value, label) do
    case Enum.find(MediaCategory.all(), &(to_string(&1) == value)) do
      nil -> label
      category -> StatusLabels.media_category(category)
    end
  end

  defp value_label("monitored", "true", _label), do: gettext("Yes (Monitored)")
  defp value_label("monitored", "false", _label), do: gettext("No (Not Monitored)")
  defp value_label(_field, _value, label), do: label

  @doc """
  Translates one error string from `Mydia.Collections.SmartRules.validate/1`.
  Unknown strings are returned as they are.
  """
  @spec validation_error(String.t()) :: String.t()
  def validation_error(error) do
    case translate_error(error) do
      {:ok, translated} -> translated
      :error -> error
    end
  end

  @doc "The flash for a rejected rule set: every validator error, translated."
  @spec invalid_rules_message([String.t()]) :: String.t()
  def invalid_rules_message(errors) do
    gettext("Invalid smart rules: %{errors}",
      errors: Enum.map_join(errors, ", ", &validation_error/1)
    )
  end

  @doc """
  Whether `validation_error/1` has a msgid for this domain sentence. A new
  validator message that returns false here needs a template in this module.
  """
  @spec known?(String.t()) :: boolean()
  def known?(error), do: match?({:ok, _}, translate_error(error))

  defp translate_error("Invalid JSON"), do: {:ok, gettext("Invalid JSON")}

  defp translate_error("Rules must be a map or JSON string"),
    do: {:ok, gettext("Rules must be a map or JSON string")}

  defp translate_error("match_type must be 'all' or 'any'"),
    do: {:ok, gettext("match_type must be 'all' or 'any'")}

  defp translate_error("conditions must be a list"),
    do: {:ok, gettext("conditions must be a list")}

  defp translate_error("sort must be an object"), do: {:ok, gettext("sort must be an object")}

  defp translate_error("limit must be a positive integer"),
    do: {:ok, gettext("limit must be a positive integer")}

  defp translate_error(error) do
    cond do
      match = Regex.run(~r/^sort\.field '(.*)' is invalid$/s, error) ->
        {:ok, gettext("sort.field '%{value}' is invalid", value: Enum.at(match, 1))}

      match = Regex.run(~r/^sort\.direction '(.*)' is invalid$/s, error) ->
        {:ok, gettext("sort.direction '%{value}' is invalid", value: Enum.at(match, 1))}

      match = Regex.run(~r/^conditions\[(\d+)\]: (.*)$/s, error) ->
        [_, index, detail] = match
        condition_error(index, detail)

      true ->
        :error
    end
  end

  defp condition_error(index, detail) do
    case Enum.find_value(condition_patterns(), &apply_pattern(&1, detail)) do
      nil -> :error
      build -> {:ok, build.(index)}
    end
  end

  # Each pattern maps a detail sentence to a function from the condition index
  # to a whole translated sentence. Built at call time so `gettext` sees the
  # current locale.
  defp condition_patterns do
    [
      {~r/^field is required$/,
       fn _m, i -> gettext("conditions[%{index}]: field is required", index: i) end},
      {~r/^unknown field '(.*)'$/s,
       fn [f], i ->
         gettext("conditions[%{index}]: unknown field '%{field}'", index: i, field: f)
       end},
      {~r/^operator is required$/,
       fn _m, i -> gettext("conditions[%{index}]: operator is required", index: i) end},
      {~r/^unknown operator '(.*)'$/s,
       fn [o], i ->
         gettext("conditions[%{index}]: unknown operator '%{operator}'", index: i, operator: o)
       end},
      {~r/^value is required$/,
       fn _m, i -> gettext("conditions[%{index}]: value is required", index: i) end},
      {~r/^value must be a list for operator '(.*)'$/s,
       fn [o], i ->
         gettext("conditions[%{index}]: value must be a list for operator '%{operator}'",
           index: i,
           operator: o
         )
       end},
      {~r/^value must be a \[min, max\] list for 'between'$/,
       fn _m, i ->
         gettext("conditions[%{index}]: value must be a [min, max] list for 'between'", index: i)
       end},
      {~r/^must be an object$/,
       fn _m, i -> gettext("conditions[%{index}]: must be an object", index: i) end},
      {~r/^within_last is only valid on date fields$/,
       fn _m, i ->
         gettext("conditions[%{index}]: within_last is only valid on date fields", index: i)
       end},
      {~r/^(.*) within_last requires a positive whole number of days, got: (.*)$/s,
       fn [f, v], i ->
         gettext(
           "conditions[%{index}]: %{field} within_last requires a positive whole number of days, got: %{value}",
           index: i,
           field: f,
           value: v
         )
       end},
      {~r/^invalid type value\(s\): (.*)\. Valid values: (.*)$/s,
       fn [bad, valid], i ->
         gettext(
           "conditions[%{index}]: invalid type value(s): %{invalid}. Valid values: %{valid}",
           index: i,
           invalid: bad,
           valid: valid
         )
       end},
      {~r/^invalid type value '(.*)'\. Valid values: (.*)$/s,
       fn [bad, valid], i ->
         gettext(
           "conditions[%{index}]: invalid type value '%{invalid}'. Valid values: %{valid}",
           index: i,
           invalid: bad,
           valid: valid
         )
       end},
      {~r/^(.*) requires text values, got: (.*)$/s,
       fn [f, v], i ->
         gettext("conditions[%{index}]: %{field} requires text values, got: %{value}",
           index: i,
           field: f,
           value: v
         )
       end},
      {~r/^(.*) requires a text value, got: (.*)$/s,
       fn [f, v], i ->
         gettext("conditions[%{index}]: %{field} requires a text value, got: %{value}",
           index: i,
           field: f,
           value: v
         )
       end},
      {~r/^(.*) between requires two numeric values$/s,
       fn [f], i ->
         gettext("conditions[%{index}]: %{field} between requires two numeric values",
           index: i,
           field: f
         )
       end},
      {~r/^(.*) requires numeric values, got: (.*)$/s,
       fn [f, v], i ->
         gettext("conditions[%{index}]: %{field} requires numeric values, got: %{value}",
           index: i,
           field: f,
           value: v
         )
       end},
      {~r/^(.*) requires a numeric value, got: (.*)$/s,
       fn [f, v], i ->
         gettext("conditions[%{index}]: %{field} requires a numeric value, got: %{value}",
           index: i,
           field: f,
           value: v
         )
       end},
      {~r/^(.*) requires true or false, got: (.*)$/s,
       fn [f, v], i ->
         gettext("conditions[%{index}]: %{field} requires true or false, got: %{value}",
           index: i,
           field: f,
           value: v
         )
       end}
    ]
  end

  defp apply_pattern({regex, builder}, detail) do
    case Regex.run(regex, detail) do
      nil -> nil
      [_whole | captures] -> fn index -> builder.(captures, index) end
    end
  end
end
