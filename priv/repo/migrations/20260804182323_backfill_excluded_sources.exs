defmodule Mydia.Repo.Migrations.BackfillExcludedSources do
  @moduledoc """
  Backfills `quality_standards.excluded_sources` onto every existing quality
  profile so upgrading instances stop grabbing camcorder captures.

  Downloading a telesync is not a preference anyone tuned a profile to express,
  so this corrects a default rather than overriding a choice. The field stays
  per-profile and editable, and profiles that already carry the key (including
  an operator who deliberately cleared it) are left untouched.

  `quality_standards` is a JSON text column, so this is a read-modify-write in
  Elixir and runs identically on SQLite and PostgreSQL.
  """
  use Ecto.Migration

  import Ecto.Query

  # Inlined rather than calling Mydia.Quality.Sources.cam_tier/0 so a later
  # change to that list cannot retroactively alter what this migration did.
  @cam_tier ["CAM", "Telesync", "Telecine", "Screener", "Workprint"]

  def up do
    repo().all(from(p in "quality_profiles", select: {p.id, p.quality_standards}))
    |> Enum.each(fn {id, raw} ->
      standards = decode(raw)

      unless Map.has_key?(standards, "excluded_sources") do
        updated = Map.put(standards, "excluded_sources", @cam_tier)

        repo().update_all(
          from(p in "quality_profiles", where: p.id == ^id),
          set: [quality_standards: Jason.encode!(updated)]
        )
      end
    end)
  end

  # Irreversible by design: we cannot distinguish a profile we backfilled from
  # one an operator configured identically afterwards, and removing the key
  # would silently re-enable cam grabs.
  def down, do: :ok

  defp decode(nil), do: %{}
  defp decode(""), do: %{}

  defp decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp decode(map) when is_map(map), do: map
  defp decode(_), do: %{}
end
