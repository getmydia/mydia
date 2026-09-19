defmodule Mydia.Indexers.ReleaseIdentity do
  @moduledoc """
  Decides whether a release name is the media item it was found for.

  A release matches when its parsed title, reduced to a
  `Mydia.Library.Text.match_key/1` key, equals the key of the item's title or
  one of its alternative titles and, for movies, its year is within one of the
  item's. This is the clean-title comparison Sonarr and Radarr use:
  punctuation, spacing and filler words cannot make two names differ, and a
  name that merely starts with the title does not match it.
  """

  alias Mydia.Indexers.ReleaseIdentity.Target
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Library.Text

  @type verdict :: :match | {:mismatch, :title | :year}

  # ReleaseParser keeps a leading "[Group]" tag in the title it returns.
  @leading_tags ~r/^\s*(\[[^\]]*\]\s*)+/
  @year_token ~r/^(19|20)\d{2}$/

  @spec check(String.t(), Target.t()) :: verdict()
  def check(release_title, %Target{} = target) when is_binary(release_title) do
    name = String.replace(release_title, @leading_tags, "")

    case ReleaseParser.parse(name) do
      %ParsedFileInfo{title: title, year: year} when is_binary(title) and title != "" ->
        if Text.match_key(title) in target.keys,
          do: check_year(year, target),
          else: {:mismatch, :title}

      _ ->
        check_leading_tokens(Text.match_tokens(name), target)
    end
  end

  # With no parsed title the parser usually read the title itself as the year
  # ("2043.2031.1080p" parses with year 2043), so the name is matched on its
  # leading tokens and the release year is the first year-shaped token after
  # them. An air-dated name ("2031-05-12 Other Title") never matches this way.
  defp check_leading_tokens(tokens, target) do
    matched =
      Enum.find(1..length(tokens)//1, fn count ->
        (tokens |> Enum.take(count) |> Enum.join()) in target.keys
      end)

    case matched do
      nil ->
        {:mismatch, :title}

      count ->
        tokens
        |> Enum.drop(count)
        |> Enum.find(&(&1 =~ @year_token))
        |> year_value()
        |> check_year(target)
    end
  end

  defp year_value(nil), do: nil
  defp year_value(token), do: String.to_integer(token)

  defp check_year(_year, %Target{type: :tv_show}), do: :match

  defp check_year(year, %Target{year: expected})
       when is_integer(year) and is_integer(expected) and abs(year - expected) > 1,
       do: {:mismatch, :year}

  defp check_year(_year, _target), do: :match
end
