defmodule Mydia.Media.EpisodePlaceholder do
  @moduledoc """
  Recognises the stand-in values providers publish for an episode before its
  real metadata exists.

  Measured against relay.mydia.dev on 2026-09-14: TVDB names an unannounced
  episode `"TBA "` (trailing space included) or `"TBA"` and gives it a `null`
  or `"TBC"` overview, while TMDB names it after its number (`"Episode 8"`)
  with an empty overview. Neither sends a screencap until around the air date.
  See `lib/mydia/metadata/README.md`.
  """

  @placeholder_words ~w(tba tbd tbc)
  @numbered_title ~r/^episode\s*#?\d+$/

  @doc "True when an episode title is missing or a stand-in."
  @spec title?(term()) :: boolean()
  def title?(nil), do: true

  def title?(value) when is_binary(value) do
    normalized = normalize(value)
    word_placeholder?(normalized) or Regex.match?(@numbered_title, normalized)
  end

  def title?(_value), do: false

  @doc "True when an episode overview is missing or a stand-in."
  @spec overview?(term()) :: boolean()
  def overview?(nil), do: true
  def overview?(value) when is_binary(value), do: value |> normalize() |> word_placeholder?()
  def overview?(_value), do: false

  @doc "True when an episode screencap path is missing."
  @spec still?(term()) :: boolean()
  def still?(nil), do: true
  def still?(value) when is_binary(value), do: String.trim(value) == ""
  def still?(_value), do: false

  @doc """
  True when replacing the `old` title with `new` is worth reporting.

  The new title must be real and must differ from the old one once
  surrounding whitespace is ignored, so `"TBA "` becoming `"TBA"`, or
  `"Episode 8"` becoming `"TBA"`, is not a change.
  """
  @spec title_change?(String.t() | nil, String.t() | nil) :: boolean()
  def title_change?(old, new), do: not title?(new) and trimmed(old) != trimmed(new)

  defp word_placeholder?(normalized), do: normalized == "" or normalized in @placeholder_words

  defp normalize(value), do: value |> String.trim() |> String.downcase()

  defp trimmed(nil), do: ""
  defp trimmed(value) when is_binary(value), do: String.trim(value)
end
