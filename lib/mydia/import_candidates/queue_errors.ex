defmodule Mydia.ImportCandidates.QueueErrors do
  @moduledoc """
  User-facing reasons recorded in `import_candidates.queue_error` when a
  queued operation refuses a candidate.
  """

  alias Mydia.Library.ImportCandidate

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

  def message(:implausible),
    do:
      "This file's episode number is far past the show's known episodes, " <>
        "so it wasn't created. Check the file name."

  def message({:incompatible_media_type, _, _}),
    do: "This file's type doesn't match the matched title (movie or show)."

  def message(:mixed_group), do: "Files in this group belong to different folders."

  def message({reason, _})
      when reason in [:invalid_provider_id, :invalid_match_result],
      do: "The match is missing a usable provider ID. Re-match this group."

  # Only reached for the not_found case: callers format terminal reasons only.
  def message({:metadata_fetch_failed, _}),
    do: "The matched title no longer exists at the provider. Re-match this group."

  def message({:no_file_imported, _entries}), do: "No file in this group could be imported."

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

  @doc """
  The reason written to one candidate's row: `message/1`, with the episode it
  couldn't place where that is what went wrong.
  """
  @spec file_message(term(), ImportCandidate.t()) :: String.t()
  def file_message(reason, %ImportCandidate{} = candidate)
      when reason in [:implausible, :unresolved_episode] do
    case coordinate(candidate) do
      nil ->
        "No season and episode number. Set them on this row."

      {0, label} when reason == :implausible ->
        "#{label} isn't one of this show's specials at the metadata provider, " <>
          "so it can't be imported. Check the season and episode."

      {_season, label} when reason == :implausible ->
        "#{label} is far past this show's known episodes, so it wasn't created. " <>
          "Check the season and episode."

      {_season, label} ->
        "#{label} isn't in this show's episode list."
    end
  end

  def file_message(reason, _candidate), do: message(reason)

  defp coordinate(%ImportCandidate{parsed_info: %{} = info}) do
    season = Map.get(info, "season")
    episodes = info |> Map.get("episodes") |> List.wrap()

    if is_integer(season) and episodes != [] and Enum.all?(episodes, &is_integer/1) do
      {season, "S#{pad(season)}E#{pad(hd(episodes))}" <> range_suffix(episodes)}
    end
  end

  defp coordinate(_candidate), do: nil

  defp range_suffix([_]), do: ""
  defp range_suffix(episodes), do: "-E#{pad(List.last(episodes))}"

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  # Foreign keys and :base are internal; their messages read as full sentences.
  # Other fields get a prefix so "can't be blank" says what is blank.
  defp changeset_error_line(field, message) do
    if field == :base or String.ends_with?(to_string(field), "_id"),
      do: message,
      else: "#{field} #{message}"
  end
end
