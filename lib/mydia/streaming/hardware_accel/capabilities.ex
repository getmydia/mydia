defmodule Mydia.Streaming.HardwareAccel.Capabilities do
  @moduledoc """
  What the host's video hardware can actually do, as measured by
  `Mydia.Streaming.HardwareAccel.Probe`.

  `backend: :none` is the normal, supported state: most installs have no usable
  device, and every consumer must treat software as the default rather than as a
  failure. `reason` is what separates "no GPU here", "a GPU is present but its
  driver is missing", and "an operator turned this off", which lead to three
  different actions and must not collapse into a bare `:none`.
  """

  @known_codecs %{
    "h264" => :h264,
    "hevc" => :hevc,
    "h265" => :hevc,
    "av1" => :av1,
    "vp9" => :vp9,
    "vp8" => :vp8,
    "mpeg2video" => :mpeg2video,
    "vc1" => :vc1
  }

  defstruct backend: :none, device: nil, encoders: [], decode_profiles: [], reason: nil

  @type backend :: :vaapi | :none
  @type codec :: :h264 | :hevc | :av1 | :vp9 | :vp8 | :mpeg2video | :vc1

  @type t :: %__MODULE__{
          backend: backend(),
          device: String.t() | nil,
          encoders: [codec()],
          decode_profiles: [codec()],
          reason: String.t() | nil
        }

  @doc "Capabilities meaning 'encode in software', carrying why."
  @spec software(String.t()) :: t()
  def software(reason) when is_binary(reason), do: %__MODULE__{backend: :none, reason: reason}

  @spec accelerated?(t()) :: boolean()
  def accelerated?(%__MODULE__{backend: :none}), do: false
  def accelerated?(%__MODULE__{}), do: true

  @doc """
  Whether the device can decode `codec` in hardware.

  Accepts the atom or the string ffprobe reported. An unrecognised string is
  never a hardware decode: the lookup table is closed so that a codec name
  arriving from file metadata cannot mint an atom.
  """
  @spec can_decode?(t(), codec() | String.t() | nil) :: boolean()
  def can_decode?(caps, codec), do: member?(caps, :decode_profiles, codec)

  @spec can_encode?(t(), codec() | String.t() | nil) :: boolean()
  def can_encode?(caps, codec), do: member?(caps, :encoders, codec)

  @doc "Maps an ffprobe codec name onto a known atom, or nil."
  @spec codec_atom(codec() | String.t() | nil) :: codec() | nil
  def codec_atom(codec) when is_atom(codec) and not is_nil(codec) do
    if codec in Map.values(@known_codecs), do: codec, else: nil
  end

  def codec_atom(codec) when is_binary(codec) do
    Map.get(@known_codecs, String.downcase(codec))
  end

  def codec_atom(_), do: nil

  defp member?(%__MODULE__{backend: :none}, _field, _codec), do: false

  defp member?(%__MODULE__{} = caps, field, codec) do
    case codec_atom(codec) do
      nil -> false
      atom -> atom in Map.fetch!(caps, field)
    end
  end
end
