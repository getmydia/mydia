defmodule Mydia.Library.Structs.FileAnalysisResult do
  @moduledoc """
  Represents technical metadata extracted from a video file via FFprobe.

  This struct provides compile-time safety for file analysis results,
  containing video and audio technical specifications.

  This differs from Quality (parsed from filenames) which contains
  user-friendly quality indicators.

  ## Fields

  - `:resolution` - Video resolution (e.g., "1080p", "4K", "720p")
  - `:codec` - Video codec (e.g., "H.264", "HEVC", "AV1")
  - `:audio_codec` - Audio codec with channel info (e.g., "AAC 5.1", "DTS-HD MA")
  - `:bitrate` - Video bitrate in bits per second
  - `:hdr_format` - HDR format if present (e.g., "HDR10", "Dolby Vision")
  - `:size` - File size in bytes

  All fields are optional as FFprobe may not be able to extract all metadata.
  """

  defstruct [:resolution, :codec, :audio_codec, :bitrate, :hdr_format, :size]

  @type t :: %__MODULE__{
          resolution: String.t() | nil,
          codec: String.t() | nil,
          audio_codec: String.t() | nil,
          bitrate: integer() | nil,
          hdr_format: String.t() | nil,
          size: integer() | nil
        }

  @doc """
  Creates a new FileAnalysisResult struct.

  ## Examples

      iex> new(resolution: "1080p", codec: "H.264", size: 2_147_483_648)
      %FileAnalysisResult{resolution: "1080p", codec: "H.264", size: 2_147_483_648, ...}
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Creates an empty FileAnalysisResult with all fields set to nil.

  ## Examples

      iex> empty()
      %FileAnalysisResult{resolution: nil, codec: nil, ...}
  """
  def empty do
    %__MODULE__{}
  end
end
