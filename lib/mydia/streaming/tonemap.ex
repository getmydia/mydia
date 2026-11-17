defmodule Mydia.Streaming.Tonemap do
  @moduledoc """
  What this server's ffmpeg can do to turn HDR video into SDR.

  The capability is probed once at boot and stored with `put_current/1`.
  `current/0` is a `:persistent_term` read, not a GenServer call, so resolving
  per-file GraphQL fields (a streaming candidate list touches one capability
  check per file) never queues behind a process.

  The default is `none/0`: until a probe says otherwise the server claims no
  tonemapping, and `Mydia.Streaming.Compatibility` keeps treating HDR files as
  direct play, which is what it did before this module existed.
  """

  alias Mydia.Library.Hdr

  defstruct zscale: false, libplacebo: false, vaapi: false

  @type t :: %__MODULE__{zscale: boolean(), libplacebo: boolean(), vaapi: boolean()}

  @key {__MODULE__, :current}

  @doc "A server that cannot tonemap anything."
  @spec none() :: t()
  def none, do: %__MODULE__{}

  @doc """
  Whether this server can produce a correct SDR picture from `hdr`.

  SDR needs nothing, so it is always true. Dolby Vision profile 5 has no
  display-compatible base layer, so only libplacebo can reshape it. Everything
  else needs a tonemap filter, either zscale or libplacebo.
  """
  @spec can_tonemap?(t(), Hdr.t()) :: boolean()
  def can_tonemap?(%__MODULE__{} = tonemap, %Hdr{} = hdr) do
    cond do
      Hdr.sdr?(hdr) -> true
      hdr.base == nil -> tonemap.libplacebo
      true -> tonemap.zscale or tonemap.libplacebo
    end
  end

  @doc "The probed capability, or `none/0` before anything was stored."
  @spec current() :: t()
  def current, do: :persistent_term.get(@key, none())

  @doc "Stores the probed capability for `current/0`."
  @spec put_current(t()) :: :ok
  def put_current(%__MODULE__{} = tonemap), do: :persistent_term.put(@key, tonemap)
end
