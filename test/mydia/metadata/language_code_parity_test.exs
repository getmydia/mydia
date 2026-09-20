defmodule Mydia.Metadata.LanguageCodeParityTest do
  @moduledoc """
  The player and the server both decide whether two language tags name the same
  language, about the same file, for the same viewer: the server in
  `Mydia.Streaming.SubtitlePreferences.operator_default/1` through
  `LanguageCode.matches?/2`, the player when matching a stored preference
  against a track list. The preference is stored server-side, so two tables of
  different sizes are two answers to one question.

  The player cannot read this module, so it carries a transcription. This is
  what stops the two drifting: add a language to one side only and this fails.

  It fails here, in `mix test`, rather than in the Flutter suite, because
  Elixir can read the Dart file and the reverse is not true.
  """
  use ExUnit.Case, async: true

  alias Mydia.Metadata.LanguageCode

  @dart_file "player/lib/core/language/language_equivalents.dart"

  test "the player's table matches @equivalents exactly" do
    assert parse_dart_table() == LanguageCode.equivalents_table(),
           """
           #{@dart_file} and Mydia.Metadata.LanguageCode's @equivalents have \
           drifted. Add the language to both, keeping ISO 639-2/T before /B in \
           each list.
           """
  end

  # Reads the `kLanguageEquivalents` literal out of the Dart source. A regex
  # rather than a parser on purpose: the map is a flat literal of quoted
  # strings, and anything cleverer would be more code than the thing it checks.
  defp parse_dart_table do
    source = File.read!(Path.join(project_root(), @dart_file))

    [_, body] =
      Regex.run(
        ~r/const Map<String, List<String>> kLanguageEquivalents = \{(.*?)\n\};/s,
        source
      )

    ~r/'([a-z]{2})':\s*\[([^\]]*)\]/
    |> Regex.scan(body)
    |> Map.new(fn [_, two, threes] ->
      {two,
       threes
       |> String.split(",")
       |> Enum.map(&String.trim/1)
       |> Enum.reject(&(&1 == ""))
       |> Enum.map(&String.trim(&1, "'"))}
    end)
  end

  # The suite runs from the umbrella root, but say so rather than assume it.
  defp project_root, do: File.cwd!()
end
