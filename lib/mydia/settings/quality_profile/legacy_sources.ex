defmodule Mydia.Settings.QualityProfile.LegacySources do
  @moduledoc """
  Folds source names older quality profiles may still carry (YAML/env
  config, imports, rows from before the fold) into what they mean now.

  Both parsers fold `BDRip` and `BRRip` into `BluRay`, so a profile naming
  them could never match a release or a file.
  """

  import Ecto.Changeset

  @aliases %{"BDRip" => "BluRay", "BRRip" => "BluRay"}

  @doc """
  Rewrites legacy source names in a quality-profile changeset's
  `quality_standards` change rather than rejecting them, so a profile that
  still lists "BDRip" keeps loading.

  A preference folds to BluRay, with duplicates collapsing onto the first
  occurrence to keep the priority order. An exclusion is dropped instead:
  excluding BluRay would silently block every Blu-ray release, far more
  than the operator asked.
  """
  @spec fold(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def fold(changeset) do
    update_change(changeset, :quality_standards, fn
      standards when is_map(standards) ->
        standards
        |> update_source_list(:preferred_sources, fn sources ->
          sources |> Enum.map(&Map.get(@aliases, &1, &1)) |> Enum.uniq()
        end)
        |> update_source_list(:excluded_sources, fn sources ->
          Enum.reject(sources, &Map.has_key?(@aliases, &1))
        end)

      other ->
        other
    end)
  end

  defp update_source_list(standards, key, fun) do
    case Map.get(standards, key) do
      sources when is_list(sources) -> Map.put(standards, key, fun.(sources))
      _ -> standards
    end
  end
end
