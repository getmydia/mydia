defmodule Mydia.Streaming.Tonemap.Filters do
  @moduledoc """
  Which of the tonemap filters of interest `ffmpeg -filters` lists.

  A listing is not proof a filter works; see `Mydia.Streaming.Tonemap.Probe`.
  """

  @type t :: %__MODULE__{
          zscale: boolean(),
          tonemap: boolean(),
          libplacebo: boolean(),
          tonemap_vaapi: boolean()
        }

  defstruct zscale: false, tonemap: false, libplacebo: false, tonemap_vaapi: false
end
