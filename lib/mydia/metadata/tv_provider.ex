defmodule Mydia.Metadata.TvProvider do
  @moduledoc """
  The two providers a TV show can take its metadata from, `:tvdb` and `:tmdb`.

  A library picks one through `library_paths.tv_metadata_source`, and a single
  show can be pinned to the other (see `Mydia.Media.ProviderSwitch.pin_for/2`).
  """

  @type t :: :tvdb | :tmdb

  @doc "Parses a provider sent by a form or event. Anything else is nil."
  @spec parse(term()) :: t() | nil
  def parse("tvdb"), do: :tvdb
  def parse("tmdb"), do: :tmdb
  def parse(_), do: nil

  @doc "The provider that is not `provider`, or nil when `provider` is not a TV provider."
  @spec other(term()) :: t() | nil
  def other(:tvdb), do: :tmdb
  def other(:tmdb), do: :tvdb
  def other(_), do: nil

  @doc "Display name for a provider given as an atom or a string, or nil for anything else."
  @spec label(term()) :: String.t() | nil
  def label(provider) when provider in [:tvdb, "tvdb"], do: "TVDB"
  def label(provider) when provider in [:tmdb, "tmdb"], do: "TMDB"
  def label(_), do: nil

  @doc """
  The library's TV provider. Only series and mixed libraries have one: the
  column defaults to `:tvdb` on every library type, so a movies library (or no
  library) reports nil.
  """
  @spec for_library(map() | nil) :: t() | nil
  def for_library(%{type: type, tv_metadata_source: source}) when type in [:series, :mixed],
    do: source

  def for_library(_library_path), do: nil
end
