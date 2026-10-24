defmodule MydiaWeb.GettextPoTest do
  @moduledoc """
  Guards against a translation that would crash a page or drop a value.
  Gettext raises when a msgstr names a binding the call does not pass, so a
  msgstr may only use keys its msgid uses (plus `count` for plurals, which
  ngettext always binds). A msgstr that omits a key silently loses the value,
  so singulars must use exactly the msgid's keys and every plural form must use
  all of them, except `count`, which a form may leave out ("one" in Spanish).
  Empty msgstrs are untranslated and skipped. Weblate PRs run this in CI.
  """
  use ExUnit.Case, async: true

  @dir Path.expand("../../priv/gettext", __DIR__)
  @files Mydia.Locale.Catalog.po_files(@dir)

  defp keys(iodata),
    do:
      ~r/%\{(\w+)\}/
      |> Regex.scan(IO.iodata_to_binary(iodata))
      |> MapSet.new(fn [_, k] -> k end)

  defp translated?(str), do: IO.iodata_to_binary(str) != ""

  # Returns {msgid, extra_keys, missing_keys} for a msgstr that disagrees with
  # the keys it may use (allowed) and must use (required).
  defp problem(id, str, allowed, required) do
    extra = MapSet.difference(keys(str), allowed)
    missing = MapSet.difference(required, keys(str))

    if MapSet.size(extra) == 0 and MapSet.size(missing) == 0,
      do: nil,
      else: {IO.iodata_to_binary(id), extra, missing}
  end

  test "there is at least one non-English catalog" do
    assert Enum.any?(@files, &(not String.contains?(&1, "/en/")))
  end

  for path <- @files do
    @path path

    test "#{Path.relative_to(path, @dir)} uses exactly the placeholders its msgid has" do
      messages = Expo.PO.parse_file!(@path)

      bad =
        for message <- messages.messages, not message.obsolete, reduce: [] do
          acc ->
            case message do
              %Expo.Message.Singular{msgid: id, msgstr: str} ->
                if translated?(str),
                  do: [problem(id, str, keys(id), keys(id)) | acc],
                  else: acc

              %Expo.Message.Plural{msgid: id, msgid_plural: pl, msgstr: forms} ->
                declared = MapSet.union(keys(id), keys(pl))
                allowed = MapSet.put(declared, "count")
                required = MapSet.delete(declared, "count")

                forms
                |> Enum.filter(fn {_i, str} -> translated?(str) end)
                |> Enum.reduce(acc, fn {_i, str}, acc ->
                  [problem(id, str, allowed, required) | acc]
                end)
            end
        end
        |> Enum.reject(&is_nil/1)

      assert bad == [], "placeholder mismatch {msgid, extra, missing}: #{inspect(bad)}"
    end

    test "#{Path.relative_to(path, @dir)} has a parseable Plural-Forms header, if any" do
      messages = Expo.PO.parse_file!(@path)

      case Expo.Messages.get_header(messages, "Plural-Forms") do
        [] -> :ok
        [header | _] -> assert {:ok, _} = Expo.PluralForms.parse(header)
      end
    end
  end
end
