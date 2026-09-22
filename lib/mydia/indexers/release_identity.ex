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
  @aka ~r/\s+a\.?k\.?a\.?\s+/i
  # Year, S01 / S01E02 / 1x02, or resolution: where a release's title ends.
  @title_end ~r/^((19|20)\d{2}|s\d{1,2}(e\d+)?|\d{1,2}x\d+|\d{3,4}p)$/

  @spec check(String.t(), Target.t()) :: verdict()
  def check(release_title, %Target{} = target) when is_binary(release_title) do
    name = String.replace(release_title, @leading_tags, "")

    case ReleaseParser.parse(name) do
      %ParsedFileInfo{title: title, year: year} when is_binary(title) and title != "" ->
        if Enum.any?(title_keys(title) ++ title_keys(raw_title(name)), &(&1 in target.keys)),
          do: check_year(year, target),
          else: {:mismatch, :title}

      _ ->
        check_leading_tokens(Text.match_tokens(name), target)
    end
  end

  # Every word before the first year, season or resolution marker. The parser
  # strips words it takes for language tags wherever they sit ("The Italian
  # Harbor" parses as "The Harbor", "Multi Season Show" as "Season Show"), so
  # the name's own leading words are a second candidate beside its title.
  defp raw_title(name) do
    name
    |> Text.match_tokens()
    |> Enum.take_while(&(not (&1 =~ @title_end)))
    |> Enum.join(" ")
  end

  # The keys a parsed title may be known by. A release names a film twice in
  # two ways: "Title AKA Other Title", and a title in another script beside
  # the Latin one ("港风边.The.Harbor's.Edge"). Each AKA side is a candidate,
  # and so is each with its non-Latin words trimmed from both ends. The whole
  # of a candidate still has to equal a target key, so trimming never lets a
  # Latin name that merely starts with the title through.
  defp title_keys(title) do
    title
    |> String.split(@aka, trim: true)
    |> Enum.flat_map(fn side ->
      tokens = Text.match_tokens(side)
      [tokens, trim_non_latin(tokens)]
    end)
    |> Enum.map(&Enum.join/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp trim_non_latin(tokens) do
    tokens
    |> Enum.drop_while(&(not latin?(&1)))
    |> Enum.reverse()
    |> Enum.drop_while(&(not latin?(&1)))
    |> Enum.reverse()
  end

  # match_tokens/1 has already folded accents, so a Latin word keeps a-z.
  defp latin?(token), do: token =~ ~r/[a-z0-9]/

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
