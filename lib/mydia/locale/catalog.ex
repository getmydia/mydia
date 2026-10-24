defmodule Mydia.Locale.Catalog do
  @moduledoc """
  Reads a gettext directory: which locales it holds and how much of each is
  translated. `Mydia.Locale` calls it at compile time.

  A message counts as translated when every `msgstr` is non-empty and it is
  not fuzzy, because Gettext serves neither empty nor fuzzy entries. Obsolete
  (`#~`) entries are not counted at all.
  """

  alias Expo.Message

  @spec po_files(Path.t()) :: [Path.t()]
  def po_files(dir), do: dir |> Path.join("*/LC_MESSAGES/*.po") |> Path.wildcard() |> Enum.sort()

  @spec scan(Path.t()) :: %{String.t() => {non_neg_integer(), non_neg_integer()}}
  def scan(dir) do
    dir
    |> po_files()
    |> Enum.reduce(%{}, fn path, acc ->
      [code | _] = path |> Path.relative_to(dir) |> Path.split()
      counts = path |> Expo.PO.parse_file!() |> count()
      Map.update(acc, code, counts, fn {d, t} -> {d + elem(counts, 0), t + elem(counts, 1)} end)
    end)
  end

  defp count(%Expo.Messages{messages: messages}) do
    live = Enum.reject(messages, & &1.obsolete)
    {Enum.count(live, &translated?/1), length(live)}
  end

  defp translated?(%Message.Singular{msgstr: msgstr} = message),
    do: not fuzzy?(message) and filled?(msgstr)

  defp translated?(%Message.Plural{msgstr: forms} = message),
    do: not fuzzy?(message) and forms != %{} and Enum.all?(Map.values(forms), &filled?/1)

  defp fuzzy?(message), do: Message.has_flag?(message, "fuzzy")
  defp filled?(msgstr), do: IO.iodata_to_binary(msgstr) != ""
end
