defmodule Mydia.Indexers.Cardigann.TextFields do
  @moduledoc false
  # Parsed definitions keep `fields` in a map, so definition order is gone by the
  # time rows are parsed. A text field may reference another text field
  # (`{{ .Result.title_phase1 }}`), so they are ordered by what they reference: a
  # field is computed after every text field its template names. A reference
  # cycle falls back to name order for whatever is left.

  @doc "True for a field computed from a `text:` template rather than a selector."
  @spec text_field?(term()) :: boolean()
  def text_field?(config) when is_map(config) do
    text = Map.get(config, :text) || Map.get(config, "text")
    is_binary(text) and text != ""
  end

  def text_field?(_config), do: false

  @doc "Orders `{name, config}` text fields so each follows the text fields it reads."
  @spec order([{atom() | String.t(), map()}]) :: [{atom() | String.t(), map()}]
  def order(text_fields) do
    names = MapSet.new(text_fields, fn {name, _} -> to_string(name) end)

    text_fields
    |> Enum.map(fn {name, config} ->
      {to_string(name), deps(name, config, names), {name, config}}
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> do_order(MapSet.new(), [])
  end

  defp deps(name, config, names) do
    template = if is_map(config), do: Map.get(config, :text) || Map.get(config, "text")

    ~r/\.Result\.([A-Za-z0-9_]+)/
    |> Regex.scan(to_string(template), capture: :all_but_first)
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
