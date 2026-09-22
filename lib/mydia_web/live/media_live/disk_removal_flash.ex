defmodule MydiaWeb.MediaLive.DiskRemovalFlash do
  @moduledoc """
  Flash messages for deleting media items, shared by the detail page and the
  library's bulk delete so both describe a `Mydia.Media.DiskRemoval` the
  same way.

  A folder kept because it holds other media is `:info`: that is the safety
  rule working. Files or folders that could not be removed are `:error`. The
  layout renders only those two kinds.
  """

  alias Mydia.Media.DiskRemoval

  @named_folders 3

  @doc "Flash for deleting one item: `{kind, message}`."
  @spec for_item(String.t(), boolean(), DiskRemoval.t()) :: {:info | :error, String.t()}
  def for_item(title, false, _removal),
    do: {:info, "#{title} removed from library (files preserved)"}

  def for_item(title, true, %DiskRemoval{} = removal) do
    headline =
      if removal.files_failed > 0 do
        "#{title} removed, but #{files(removal.files_failed)} could not be deleted from disk. " <>
          "Check permissions and remove them manually."
      else
        "#{title} deleted from disk."
      end

    {kind(removal), sentences([headline | folder_sentences(removal)])}
  end

  @doc "Flash for deleting `count` items at once: `{kind, message}`."
  @spec for_items(non_neg_integer(), boolean(), DiskRemoval.t()) :: {:info | :error, String.t()}
  def for_items(count, false, _removal),
    do: {:info, "#{items(count)} removed from library (files preserved)"}

  def for_items(count, true, %DiskRemoval{} = removal) do
    headline =
      if removal.files_failed > 0 do
        "#{items(count)} deleted, but #{files(removal.files_failed)} could not be removed " <>
          "from disk. Check permissions and remove them manually."
      else
        "#{items(count)} deleted from disk."
      end

    {kind(removal), sentences([headline | folder_sentences(removal)])}
  end

  defp kind(%DiskRemoval{files_failed: failed}) when failed > 0, do: :error

  defp kind(%DiskRemoval{folders_kept: kept}) do
    if Enum.any?(kept, &match?({_path, {:error, _}}, &1)), do: :error, else: :info
  end

  defp folder_sentences(%DiskRemoval{folders_kept: kept}) do
    blocked = for {path, {:blocked, _}} <- kept, do: path
    failed = for {path, {:error, reason}} <- kept, do: "Couldn't remove #{path} (#{reason})."

    Enum.reject([blocked_sentence(blocked) | failed], &is_nil/1)
  end

  defp blocked_sentence([]), do: nil
  defp blocked_sentence([path]), do: "Kept #{path} because it holds other media."

  defp blocked_sentence(paths) do
    named = paths |> Enum.take(@named_folders) |> Enum.join(", ")
    more = length(paths) - @named_folders
    suffix = if more > 0, do: " and #{more} more", else: ""

    "Kept #{length(paths)} folders that hold other media: #{named}#{suffix}."
  end

  defp sentences(list), do: Enum.join(list, " ")

  defp files(1), do: "1 file"
  defp files(n), do: "#{n} files"

  defp items(1), do: "1 item"
  defp items(n), do: "#{n} items"
end
