defmodule Mydia.Library.Hdr do
  @moduledoc """
  The canonical HDR representation. Nothing else in the codebase decides what
  HDR a file has.

  ## Why a base plus a Dolby Vision profile, and not one enum

  Dolby Vision profile 8.1 is an enhancement layer on top of an HDR10 base, and
  8.4 sits on HLG. Such a file is genuinely both formats at once, and the single
  `hdr_format` string this module replaces forced it to lie about one of them.

  Profile 5 is the opposite case: it has no display-compatible base layer, so
  `base` is `nil` for it. That makes `base == nil` unsafe as a test for "is this
  SDR". Use `sdr?/1`, which asks whether any token was derived at all.

  ## Two vocabularies, deliberately

  Atoms are the internal representation and get cast-time validation through
  `Ecto.Enum` on `Mydia.Library.MediaFile`. Quality profile preference lists stay
  strings because they are operator-authored JSON in the database.
  `profile_tokens/1` is the single crossing point between them.
  """

  defstruct base: nil, dv_profile: nil, bl_compat_id: nil

  @type base :: :hdr10 | :hdr10_plus | :hlg | nil

  @type t :: %__MODULE__{
          base: base(),
          dv_profile: pos_integer() | nil,
          bl_compat_id: non_neg_integer() | nil
        }

  # Mirrored by Ecto.Enum on MediaFile.hdr_format. A test asserts they match.
  @bases [:hdr10, :hdr10_plus, :hlg]

  # The vocabulary QualityProfile stores in its JSON preference lists.
  @profile_format_strings ["dolby_vision", "hdr10+", "hdr10", "hlg"]

  @spec bases() :: [atom()]
  def bases, do: @bases

  @spec profile_format_strings() :: [String.t()]
  def profile_format_strings, do: @profile_format_strings

  @spec dolby_vision?(t()) :: boolean()
  def dolby_vision?(%__MODULE__{dv_profile: profile}), do: is_integer(profile)

  @doc """
  Preference-list tokens for this file, most specific first.

  A format carrying a compatible base emits that base as a further token, so an
  operator who listed only "hdr10" still matches a DV 8.1 or HDR10+ file.
  """
  @spec profile_tokens(t()) :: [String.t()]
  def profile_tokens(%__MODULE__{} = hdr) do
    dv = if dolby_vision?(hdr), do: ["dolby_vision"], else: []
    dv ++ base_tokens(hdr.base)
  end

  defp base_tokens(:hdr10_plus), do: ["hdr10+", "hdr10"]
  defp base_tokens(:hdr10), do: ["hdr10"]
  defp base_tokens(:hlg), do: ["hlg"]
  defp base_tokens(nil), do: []

  @doc """
  Human-readable HDR text. The only producer of such text in the codebase.

  Every Dolby Vision variant renders as "Dolby Vision" so shipped players see
  exactly what they see today. Clients needing the profile distinction read
  `dolbyVisionProfile` and `dolbyVisionBlCompatId` instead.
  """
  @spec display(t()) :: String.t() | nil
  def display(%__MODULE__{} = hdr) do
    cond do
      dolby_vision?(hdr) -> "Dolby Vision"
      hdr.base == :hdr10_plus -> "HDR10+"
      hdr.base == :hdr10 -> "HDR10"
      hdr.base == :hlg -> "HLG"
      true -> nil
    end
  end

  @doc """
  Whether this file carries no HDR signal at all.

  Use this rather than testing `base` for nil, which is true for Dolby Vision
  profile 5.
  """
  @spec sdr?(t()) :: boolean()
  def sdr?(%__MODULE__{} = hdr), do: profile_tokens(hdr) == []
end
