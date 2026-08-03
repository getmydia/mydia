defmodule Mydia.Library.SegmentDetection.Fingerprint do
  @moduledoc """
  Behaviour for producing an audio fingerprint over a window of a media file.

  A fingerprint is one unsigned 32-bit integer per audio frame. Two recordings
  of the same audio produce near-identical hash streams, which is what
  `Correlator` exploits to locate a shared theme.

  This exists as a behaviour so the implementation can be swapped. Today it is
  `Fpcalc`, shelling out to Chromaprint. A Rust NIF alongside `mydia_p2p_core`
  would remove the external binary and run faster; that swap should be a module
  change here, not a redesign.

  Tests inject a stub via `config :mydia, :fingerprint_impl, MyStub`.
  """

  defmodule Result do
    @moduledoc """
    A fingerprint and the frame duration needed to convert it back to time.

    `frame_ms` is derived per call, never hardcoded. Chromaprint's frame rate
    depends on its algorithm version, and a wrong constant produces timestamps
    that drift further the longer the matched run.

    `window_start_ms` records where in the file this window began. The credits
    window does not start at zero, so frame positions inside it are meaningless
    without it. It is a real struct field rather than something bolted on later
    with `Map.put/3`, which would produce a struct carrying an undeclared key.
    """

    @type t :: %__MODULE__{
            hashes: [non_neg_integer()],
            frame_ms: float(),
            window_start_ms: non_neg_integer()
          }

    defstruct hashes: [], frame_ms: 0.0, window_start_ms: 0
  end

  @default_impl Mydia.Library.SegmentDetection.Fingerprint.Fpcalc

  @doc """
  Fingerprints `length_s` seconds of `path` starting at `start_s`.
  """
  @callback fingerprint(path :: String.t(), start_s :: number(), length_s :: number()) ::
              {:ok, Result.t()} | {:error, term()}

  @doc "True when the configured implementation can actually run."
  @callback available?() :: boolean()

  @doc """
  The implementation module currently configured.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:mydia, :fingerprint_impl, @default_impl)

  @doc """
  Fingerprints `length_s` seconds of `path` starting at `start_s` with the
  configured implementation.
  """
  @spec fingerprint(String.t(), number(), number()) :: {:ok, Result.t()} | {:error, term()}
  def fingerprint(path, start_s, length_s), do: impl().fingerprint(path, start_s, length_s)

  @doc """
  True when the configured implementation can actually run.
  """
  @spec available?() :: boolean()
  def available?, do: impl().available?()
end
