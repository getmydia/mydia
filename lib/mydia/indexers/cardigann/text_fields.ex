defmodule Mydia.Indexers.Cardigann.TextFields do
  @moduledoc false
  # Parsed definitions keep `fields` in a map, so definition order is gone by the
  # time rows are parsed. A text field may reference another text field
  # (`{{ .Result.title_phase1 }}`), so they are ordered by what they reference: a
  # field is computed after every text field its template names. A reference
  # cycle falls back to name order for whatever is left.

  @doc "True for a field computed from a `text:` template rather than a selector."
  @spec text_field?(term()) :: boolean()
  def text_field?(config), do: text_value(config) != nil

  @doc """
  The field's `text:` as a string, or nil when it has none. Any non-empty scalar
  counts, because YAML reads `text: 1` as an integer and it is still a text field.
  """
  @spec text_value(term()) :: String.t() | nil
  def text_value(config) when is_map(config) do
    case Map.get(config, :text) || Map.get(config, "text") do
      text when is_binary(text) and text != "" -> text
      text when is_number(text) or is_boolean(text) -> to_string(text)
      _ -> nil
    end
  end

  def text_value(_config), do: nil

  @doc """
  Orders `{name, config}` fields so each follows the fields it reads through
  `.Result`. `templates` returns the template text a config may reference
  fields in; by default the `text:` template.
  """
  @spec order([{atom() | String.t(), term()}], (term() -> String.t())) ::
          [{atom() | String.t(), term()}]
  def order(fields, templates \\ &text_template/1) do
    names = MapSet.new(fields, fn {name, _} -> to_string(name) end)

    fields
    |> Enum.map(fn {name, config} ->
      {to_string(name), deps(name, templates.(config), names), {name, config}}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> do_order(MapSet.new(), [])
  end

  defp text_template(config), do: to_string(text_value(config))

  defp deps(name, template, names) do
    ~r/\.Result\.([A-Za-z0-9_]+)/
    |> Regex.scan(template, capture: :all_but_first)
    |> List.flatten()
    |> Enum.filter(&(MapSet.member?(names, &1) and &1 != to_string(name)))
  end

  defp do_order([], _done, acc), do: Enum.reverse(acc)

  defp do_order(pending, done, acc) do
    {ready, blocked} =
      Enum.split_with(pending, fn {_n, deps, _f} -> Enum.all?(deps, &MapSet.member?(done, &1)) end)

    case ready do
      [] ->
        Enum.reverse(acc) ++ Enum.map(blocked, &elem(&1, 2))

      _ ->
        done = Enum.reduce(ready, done, fn {n, _, _}, d -> MapSet.put(d, n) end)
        do_order(blocked, done, Enum.reverse(Enum.map(ready, &elem(&1, 2))) ++ acc)
    end
  end
end
