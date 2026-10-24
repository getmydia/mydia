defmodule MydiaWeb.MediaLive.DiskRemovalFlash do
  @moduledoc """
  Flash messages for deleting media items, shared by the detail page and the
  library's bulk delete so both describe a `Mydia.Media.DiskRemoval` the
  same way.

  A folder kept because it holds other media is `:info`: that is the safety
  rule working. Files or folders that could not be removed are `:error`. The
  layout renders only those two kinds.
  """

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Media.DiskRemoval

  @named_folders 3

  @doc "Flash for deleting one item: `{kind, message}`."
  @spec for_item(String.t(), boolean(), DiskRemoval.t()) :: {:info | :error, String.t()}
  def for_item(title, false, _removal),
    do: {:info, gettext("%{title} removed from library (files preserved)", title: title)}

  def for_item(title, true, %DiskRemoval{} = removal) do
    headline =
      if removal.files_failed > 0 do
        gettext(
          "%{title} removed, but %{files} could not be deleted from disk. Check permissions and remove them manually.",
          title: title,
          files: files(removal.files_failed)
        )
      else
        gettext("%{title} deleted from disk.", title: title)
      end

    {kind(removal), sentences([headline | folder_sentences(removal)])}
  end

  @doc "Flash for deleting `count` items at once: `{kind, message}`."
  @spec for_items(non_neg_integer(), boolean(), DiskRemoval.t()) :: {:info | :error, String.t()}
  def for_items(count, false, _removal),
    do: {:info, gettext("%{items} removed from library (files preserved)", items: items(count))}

  def for_items(count, true, %DiskRemoval{} = removal) do
    headline =
      if removal.files_failed > 0 do
        gettext(
          "%{items} deleted, but %{files} could not be removed from disk. Check permissions and remove them manually.",
          items: items(count),
          files: files(removal.files_failed)
        )
      else
        gettext("%{items} deleted from disk.", items: items(count))
      end

    {kind(removal), sentences([headline | folder_sentences(removal)])}
  end

  defp kind(%DiskRemoval{files_failed: failed}) when failed > 0, do: :error

  defp kind(%DiskRemoval{folders_kept: kept}) do
    if Enum.any?(kept, &match?({_path, {:error, _}}, &1)), do: :error, else: :info
  end

  defp folder_sentences(%DiskRemoval{folders_kept: kept}) do
    blocked = for {path, {:blocked, _}} <- kept, do: path

    failed =
      for {path, {:error, reason}} <- kept,
          do: gettext("Couldn't remove %{path} (%{reason}).", path: path, reason: reason)

    Enum.reject([blocked_sentence(blocked) | failed], &is_nil/1)
  end

  defp blocked_sentence([]), do: nil

  defp blocked_sentence([path]),
    do: gettext("Kept %{path} because it holds other media.", path: path)

  defp blocked_sentence(paths) do
    named = paths |> Enum.take(@named_folders) |> Enum.join(", ")
    more = length(paths) - @named_folders

    if more > 0 do
      gettext("Kept %{count} folders that hold other media: %{folders} and %{more} more.",
        count: length(paths),
        folders: named,
        more: more
      )
    else
      gettext("Kept %{count} folders that hold other media: %{folders}.",
        count: length(paths),
        folders: named
      )
    end
  end

  defp sentences(list), do: Enum.join(list, " ")

  defp files(n), do: ngettext("%{count} file", "%{count} files", n)

  defp items(n), do: ngettext("%{count} item", "%{count} items", n)
end
