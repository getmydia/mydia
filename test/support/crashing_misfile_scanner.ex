defmodule Mydia.Library.CrashingMisfileScanner do
  @moduledoc """
  A `Mydia.Library.Misfile.scan/0` stand-in that always raises, for exercising
  `MisfiledComponent`'s scan-failure path deterministically instead of relying
  on library data that happens to make the real scan blow up.
  """

  def scan, do: raise("boom")
end
