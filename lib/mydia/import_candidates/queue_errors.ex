defmodule Mydia.ImportCandidates.QueueErrors do
  @moduledoc """
  User-facing reasons recorded in `import_candidates.queue_error` when a
  queued operation refuses a candidate.
  """

  @spec message(term()) :: String.t()
  def message(:no_match), do: "No provider match to import from."

  def message(:conflicting_providers),
    do: "Files in this folder match different titles."

  def message(:local_show), do: "Local shows are created directly, not imported."
  def message(:empty_group), do: "No files left to import."

  def message({:duplicate_path, _, _}),
    do: "A file at this path is already in the library."

  def message(:unresolved_episode),
    do:
      "Couldn't tell which episode this file is. Check that its name has a season and episode number."

  def message({:incompatible_media_type, _, _}),
    do: "This file's type doesn't match the matched title (movie or show)."

  def message(:mixed_group), do: "Files in this group belong to different folders."

  def message({reason, _})
      when reason in [:invalid_provider_id, :invalid_match_result],
      do: "The match is missing a usable provider ID. Re-match this group."

  # Only reached for the not_found case: callers format terminal reasons only.
  def message({:metadata_fetch_failed, _}),
    do: "The matched title no longer exists at the provider. Re-match this group."

  def message(%Ecto.Changeset{} = changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)
      |> Enum.flat_map(fn {field, messages} ->
        Enum.map(messages, &changeset_error_line(field, &1))
      end)
      |> Enum.join("; ")

    String.slice("This file can't be added to the library: " <> details, 0, 200)
  end

  # Foreign keys and :base are internal; their messages read as full sentences.
  # Other fields get a prefix so "can't be blank" says what is blank.
  defp changeset_error_line(field, message) do
    if field == :base or String.ends_with?(to_string(field), "_id"),
      do: message,
      else: "#{field} #{message}"
  end
end
