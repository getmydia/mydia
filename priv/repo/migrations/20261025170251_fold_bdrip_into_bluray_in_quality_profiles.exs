defmodule Mydia.Repo.Migrations.FoldBdripIntoBlurayInQualityProfiles do
  @moduledoc """
  Rewrites `BDRip` and `BRRip` to `BluRay` in every stored quality profile's
  `quality_standards.preferred_sources`, and drops them from
  `.excluded_sources`.

  Both release parsers now fold those names into `BluRay`, so a stored
  `BDRip` preference can never match a release or a file, and
  `QualityProfile` no longer accepts it as a source. The changeset does the
  same on every save; this brings rows that are never re-saved in line.

  The two lists are treated differently on purpose. Folding a preference
  keeps what the operator wanted. Folding an exclusion would exclude
  `BluRay` and silently block every Blu-ray release, far more than was
  asked, so the entry is dropped instead.

  `quality_standards` is a JSON text column on both adapters, holding
  string keys at rest, so this is a read-modify-write in Elixir. Rows that
  list neither name are left byte-for-byte untouched, which also makes a
  second run a no-op.
  """
  use Ecto.Migration

  import Ecto.Query

  # Inlined rather than read from QualityProfile so a later change there
  # cannot retroactively alter what this migration did.
  @aliases %{"BDRip" => "BluRay", "BRRip" => "BluRay"}
  @keys ["preferred_sources", "excluded_sources"]

  def up do
    repo().all(from(p in "quality_profiles", select: {p.id, p.quality_standards}))
    |> Enum.each(fn {id, raw} ->
      with {:ok, standards} <- decode(raw),
           true <- lists_legacy_source?(standards) do
        repo().update_all(
          from(p in "quality_profiles", where: p.id == ^id),
          set: [quality_standards: Jason.encode!(fold(standards))]
        )
      end
    end)
  end

  # Irreversible by design: once folded, a BluRay entry that was BDRip is
  # indistinguishable from one the operator chose, and a dropped exclusion
  # leaves nothing behind.
  def down, do: :ok

  defp lists_legacy_source?(standards) do
    Enum.any?(@keys, fn key ->
      case Map.get(standards, key) do
        sources when is_list(sources) -> Enum.any?(sources, &Map.has_key?(@aliases, &1))
        _ -> false
      end
    end)
  end

  defp fold(standards) do
    standards
    |> update_list("preferred_sources", fn sources ->
      sources |> Enum.map(&Map.get(@aliases, &1, &1)) |> Enum.uniq()
    end)
    |> update_list("excluded_sources", fn sources ->
      Enum.reject(sources, &Map.has_key?(@aliases, &1))
    end)
  end

  defp update_list(standards, key, fun) do
    case Map.get(standards, key) do
      sources when is_list(sources) -> Map.put(standards, key, fun.(sources))
      _ -> standards
    end
  end

  defp decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :skip
    end
  end

  defp decode(map) when is_map(map), do: {:ok, map}
  defp decode(_), do: :skip
end
