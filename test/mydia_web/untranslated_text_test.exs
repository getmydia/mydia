defmodule MydiaWeb.UntranslatedTextTest do
  @moduledoc """
  The web UI has no literal English: every template text node and every flash
  message goes through Gettext. See lib/mydia_web/gettext/README.md.
  """
  use ExUnit.Case, async: true

  alias Mydia.Ratchet.TemplateText

  @root Path.expand("../../lib/mydia_web", __DIR__)
  # Files allowed to contain literal English, with the reason.
  @allowed %{}

  # A flash call whose message argument is a string literal, on one line.
  @single_line [
    ~r/put_flash\([^,]*,\s*:\w+,\s*"/,
    ~r/put_flash\(\s*:\w+,\s*"/
  ]
  # The same, with the literal on the line after the kind.
  @multi_line ~r/put_flash\(\s*(?:[\w.]+,\s*)?:\w+,\s*\n\s*"/

  defp files(glob) do
    @root
    |> Path.join(glob)
    |> Path.wildcard()
    |> Enum.reject(&Map.has_key?(@allowed, Path.relative_to(&1, @root)))
  end

  test "templates have no untranslated text" do
    offenders =
      for f <- files("**/*.{ex,heex}"),
          c = TemplateText.count_file(f),
          c > 0,
          do: "#{Path.relative_to(f, @root)}: #{c}"

    assert offenders == [], "wrap these in gettext:\n" <> Enum.join(offenders, "\n")
  end

  test "flash messages are translated" do
    offenders =
      for f <- files("**/*.ex"),
          line <- literal_flash_lines(File.read!(f)),
          do: "#{Path.relative_to(f, @root)}:#{line}"

    assert offenders == [], "pass flash messages through gettext:\n" <> Enum.join(offenders, "\n")
  end

  defp literal_flash_lines(source) do
    single =
      for {text, n} <- source |> String.split("\n") |> Enum.with_index(1),
          Enum.any?(@single_line, &Regex.match?(&1, text)),
          do: n

    multi =
      for [{offset, _}] <- Regex.scan(@multi_line, source, return: :index),
          do: source |> binary_part(0, offset) |> String.split("\n") |> length()

    Enum.uniq(single ++ multi)
  end
end
