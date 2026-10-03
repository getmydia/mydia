defmodule Mydia.RequestAccessCatalog.Title do
  @moduledoc "One fictional catalog title; `certification: nil` means unrated."
  @enforce_keys [:key, :name, :type, :tmdb_id, :certification]
  defstruct [:key, :name, :type, :tmdb_id, :certification]
end
