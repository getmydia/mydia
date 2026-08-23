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

  @doc """
  Builds an `%Hdr{}` from ffprobe's video stream map and, optionally, frame
  side data from a second probe.

  The transfer function determines the base and nothing else does. Dolby Vision
  overrides it when the DOVI record carries a compatibility id, because that
  field exists precisely to declare what the base layer is.
  """
  @spec from_ffprobe(map(), [map()]) :: t()
  def from_ffprobe(video_stream, frame_side_data \\ [])

  def from_ffprobe(video_stream, frame_side_data) when is_map(video_stream) do
    dovi = dovi_record(video_stream)
    dv_profile = dovi && to_int(dovi["dv_profile"])
    bl_compat_id = dovi && to_int(dovi["dv_bl_signal_compatibility_id"])

    base =
      video_stream
      |> transfer_base()
      |> dv_base(dv_profile, bl_compat_id)
      |> promote_hdr10_plus(dv_profile, frame_side_data)

    %__MODULE__{base: base, dv_profile: dv_profile, bl_compat_id: bl_compat_id}
  end

  def from_ffprobe(_video_stream, _frame_side_data), do: %__MODULE__{}

  @doc """
  Whether a second, frame-level ffprobe pass could still change this result.

  Only a plain HDR10 result can be promoted to HDR10+, so this gates the extra
  probe to the one case that benefits and keeps it free for SDR and DV files.
  """
  @spec needs_frame_probe?(t()) :: boolean()
  def needs_frame_probe?(%__MODULE__{base: :hdr10, dv_profile: nil}), do: true
  def needs_frame_probe?(%__MODULE__{}), do: false

  @doc """
  Whether frame side data carries SMPTE ST 2094-40 dynamic metadata.

  Matching is a case-insensitive substring test because the label varies across
  ffmpeg builds.
  """
  @spec hdr10_plus?([map()] | nil) :: boolean()
  def hdr10_plus?(side_data) when is_list(side_data) do
    Enum.any?(side_data, fn entry ->
      label =
        entry
        |> Map.get("side_data_type", "")
        |> to_string()
        |> String.downcase()

      String.contains?(label, "hdr10+") or String.contains?(label, "smpte2094-40")
    end)
  end

  def hdr10_plus?(_side_data), do: false

  # A DOVI record is identified by the presence of dv_profile rather than the
  # type string, matching StreamInfo.dolby_vision_profile/1.
  defp dovi_record(stream) do
    stream
    |> Map.get("side_data_list")
    |> List.wrap()
    |> Enum.find(fn
      %{"dv_profile" => _profile} -> true
      _other -> false
    end)
  end

  defp transfer_base(stream) do
    # A case on distinct values, not an `in` list. The `in` list is what made
    # the previous HLG branch unreachable.
    case Map.get(stream, "color_transfer") do
      "smpte2084" -> :hdr10
      "arib-std-b67" -> :hlg
      _other -> nil
    end
  end

  # Profile 5 has no display-compatible base regardless of what it signals.
  defp dv_base(_transfer, 5, _bl_compat_id), do: nil
  defp dv_base(_transfer, dv, 1) when is_integer(dv), do: :hdr10
  defp dv_base(_transfer, dv, 4) when is_integer(dv), do: :hlg
  defp dv_base(_transfer, dv, 0) when is_integer(dv), do: nil
  defp dv_base(_transfer, dv, 2) when is_integer(dv), do: nil
  defp dv_base(transfer, _dv, _bl_compat_id), do: transfer

  defp promote_hdr10_plus(:hdr10, nil, frame_side_data) do
    if hdr10_plus?(frame_side_data), do: :hdr10_plus, else: :hdr10
  end

  defp promote_hdr10_plus(base, _dv_profile, _frame_side_data), do: base

  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _rest} -> int
      :error -> nil
    end
  end

  defp to_int(_value), do: nil
end
