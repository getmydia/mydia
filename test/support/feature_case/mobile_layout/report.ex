defmodule MydiaWeb.FeatureCase.MobileLayout.Report do
  @moduledoc """
  Compares a sweep's violations with its `@known` exception list.

  A known entry is `{route, width, check, selector, reason}`. `route` is the
  router pattern, with `#state` appended for a manifest state. Every violation
  needs an entry, and every entry needs a violation, so the list can only
  shrink as pages are fixed.
  """

  alias MydiaWeb.FeatureCase.MobileLayout.Violation

  def key(%Violation{} = v), do: {route_key(v), v.width, v.check, v.selector}

  def diff(violations, known) do
    known_keys = MapSet.new(known, fn {r, w, c, s, _reason} -> {r, w, c, s} end)
    seen = MapSet.new(violations, &key/1)

    unexpected = Enum.reject(violations, &MapSet.member?(known_keys, key(&1)))
    stale = Enum.reject(known, fn {r, w, c, s, _} -> MapSet.member?(seen, {r, w, c, s}) end)

    {unexpected, stale}
  end

  def format(unexpected, stale) do
    [
      Enum.map(unexpected, &format_violation/1),
      if(stale == [],
        do: [],
        else: ["\nfixed, remove from @known:" | Enum.map(stale, &("  " <> inspect(&1)))]
      )
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp format_violation(%Violation{} = v) do
    {route, width, check, selector} = key(v)

    "#{route} @#{width} #{check} #{selector} #{v.detail}\n" <>
      "  accept with: {#{inspect(route)}, #{width}, #{inspect(check)}, #{inspect(selector)}, \"<reason>\"}"
  end

  defp route_key(%Violation{route: route, state: nil}), do: route
  defp route_key(%Violation{route: route, state: state}), do: route <> "#" <> state
end
