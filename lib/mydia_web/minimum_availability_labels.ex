defmodule MydiaWeb.MinimumAvailabilityLabels do
  @moduledoc """
  Display names for the minimum availability levels, shared by the admin
  setting and the movie page override. See `Mydia.Media.MinimumAvailability`.
  """

  use Gettext, backend: MydiaWeb.Gettext

  @doc "The display name of `level`."
  @spec label(String.t()) :: String.t()
  def label("announced"), do: gettext("Announced")
  def label("in_cinemas"), do: gettext("In cinemas")
  def label("released"), do: gettext("Released")
  def label(level), do: level

  @doc "`{level, label}` pairs in `Mydia.Config.Schema.minimum_availability_levels/0` order."
  @spec options() :: [{String.t(), String.t()}]
  def options, do: Enum.map(Mydia.Config.Schema.minimum_availability_levels(), &{&1, label(&1)})
end
