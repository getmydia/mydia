defmodule Mydia.Media.ContentRating do
  @moduledoc """
  Maps a content rating string to the minimum viewer age it implies.

  Ratings reach Mydia as free text from whichever region the metadata provider
  reported, so a per-country ladder is not something an operator can configure
  once and have work. Normalizing to an age gives the admin a single dial that
  behaves the same whether a title came back rated `PG-13`, `TV-14`, or `15`.

  Matching is by string alone. The few strings shared across systems (`PG`,
  `12`, `18`) carry the same age in each, so dropping the country is safe.

  Anything unrecognized returns `nil` and is treated as unrated, which an
  active limit hides. Failing closed is deliberate: this is a parental control,
  and a rating string nobody anticipated is not evidence that a title is
  suitable.
  """

  @ratings %{
    # US film, Motion Picture Association
    "G" => 0,
    "PG" => 8,
    "PG-13" => 13,
    "R" => 17,
    "NC-17" => 18,
    # US television, TV Parental Guidelines
    "TV-Y" => 0,
    "TV-G" => 0,
    "TV-Y7" => 7,
    "TV-PG" => 8,
    "TV-14" => 14,
    "TV-MA" => 17,
    # UK, British Board of Film Classification
    "U" => 0,
    "12" => 12,
    "12A" => 12,
    "15" => 15,
    "18" => 18,
    "R18" => 18
  }

  @thresholds [
    {"All ages", 0},
    {"7+", 7},
    {"12+", 12},
    {"14+", 14},
    {"16+", 16},
    {"18+", 18}
  ]

  @doc """
  Returns the minimum viewer age for a rating string, or `nil` if unrecognized.
  """
  @spec min_age(String.t() | nil) :: non_neg_integer() | nil
  def min_age(nil), do: nil

  def min_age(rating) when is_binary(rating) do
    normalized = rating |> String.trim() |> String.upcase()

    case Map.fetch(@ratings, normalized) do
      {:ok, age} -> age
      :error -> numeric_age(normalized)
    end
  end

  def min_age(_other), do: nil

  @doc """
  Returns the `{label, age}` ladder an admin picks a limit from, ascending.
  """
  @spec thresholds() :: [{String.t(), non_neg_integer()}]
  def thresholds, do: @thresholds

  # Many European certifications are the age itself ("6", "16"). A value
  # outside 0..21 is a year or an id rather than an age, so it stays
  # unrecognized.
  defp numeric_age(value) do
    case Integer.parse(value) do
      {age, ""} when age >= 0 and age <= 21 -> age
      _ -> nil
    end
  end
end
