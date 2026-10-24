defmodule MydiaWeb.GettextPoTest do
  @moduledoc """
  Guards against a translation that would crash a page. Gettext raises when a
  msgstr names a binding the call does not pass, so every msgstr may only use
  keys its msgid uses (plus `count` for plurals, which ngettext always binds).
  Weblate PRs run this in CI.
  """
  use ExUnit.Case, async: true

  @dir Path.expand("../../priv/gettext", __DIR__)
  @files Mydia.Locale.Catalog.po_files(@dir)

  defp keys(iodata),
    do:
      ~r/%\{(\w+)\}/
      |> Regex.scan(IO.iodata_to_binary(iodata))
      |> MapSet.new(fn [_, k] -> k end)

  test "there is at least one non-English catalog" do
    assert Enum.any?(@files, &(not String.contains?(&1, "/en/")))
  end

  for path <- @files do
    @path path

    test "#{Path.relative_to(path, @dir)} uses only known placeholders" do
      messages = Expo.PO.parse_file!(@path)

      bad =
        for message <- messages.messages, not message.obsolete, reduce: [] do
          acc ->
            case message do
              %Expo.Message.Singular{msgid: id, msgstr: str} ->
                extra = MapSet.difference(keys(str), keys(id))

                if MapSet.size(extra) == 0,
                  do: acc,
                  else: [{IO.iodata_to_binary(id), extra} | acc]

              %Expo.Message.Plural{msgid: id, msgid_plural: pl, msgstr: forms} ->
                allowed = keys(id) |> MapSet.union(keys(pl)) |> MapSet.put("count")

                Enum.reduce(forms, acc, fn {_i, str}, acc ->
                  extra = MapSet.difference(keys(str), allowed)

                  if MapSet.size(extra) == 0,
                    do: acc,
                    else: [{IO.iodata_to_binary(id), extra} | acc]
                end)
            end
        end

      assert bad == [], "unknown placeholders: #{inspect(bad)}"
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
