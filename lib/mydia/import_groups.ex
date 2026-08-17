defmodule Mydia.ImportGroups do
  @moduledoc """
  Query and decision surface for import groups.

  Everything the review page reads goes through here, and every count comes
  from SQL rather than from walking a loaded collection. That is the property
  that makes the page independent of library size: the working set is one page
  of groups, never one row per file.
  """

  import Ecto.Query

  alias Mydia.Library.ImportGroup
  alias Mydia.Repo

  @auto_accept_threshold 0.85
  @default_page_size 50

  @doc """
  The confidence at or above which a group is considered settled.

  Calibrated against the production library on 2026-08-17, whose candidates
  cluster at 0.65-0.70 and 0.90-1.00 with nothing in between. Every value in
  [0.75, 0.89] produces the same partition there, so this is a robust choice
  rather than a tuned one. `Mydia.Library.FileIngest` reads the same number.
  """
  @spec auto_accept_threshold() :: float()
  def auto_accept_threshold, do: @auto_accept_threshold

  @doc """
  Which review band a group falls into.

  Disagreement beats confidence: if the group's members did not all resolve the
  same provider id, a human should look at it however certain each individual
  file was.
  """
  @spec band(ImportGroup.t()) :: :ready | :needs_attention | :no_match
  def band(%ImportGroup{provider_id: nil}), do: :no_match

  def band(%ImportGroup{} = group) do
    cond do
      disagreement?(group) -> :needs_attention
      is_nil(group.min_confidence) -> :needs_attention
      group.min_confidence >= @auto_accept_threshold -> :ready
      true -> :needs_attention
    end
  end

  defp disagreement?(%ImportGroup{evidence: %{"disagreement" => true}}), do: true
  defp disagreement?(_), do: false

  @doc "Counts pending groups per band for one library path."
  @spec band_counts(binary()) :: %{
          ready: non_neg_integer(),
          needs_attention: non_neg_integer(),
          no_match: non_neg_integer(),
          total: non_neg_integer()
        }
  def band_counts(library_path_id) do
    # Folded in Elixir rather than aggregated in SQL: `band/1` reads the JSON
    # evidence column, and CLAUDE.md forbids SQL aggregates over the kinds of
    # values this would otherwise need to CASE over on two adapters.
    ImportGroup
    |> where([g], g.library_path_id == ^library_path_id and g.status == "pending")
    |> select([g], %{
      provider_id: g.provider_id,
      min_confidence: g.min_confidence,
      evidence: g.evidence
    })
    |> Repo.all()
    |> Enum.reduce(%{ready: 0, needs_attention: 0, no_match: 0, total: 0}, fn row, acc ->
      key = band(struct(ImportGroup, row))

      acc
      |> Map.update!(key, &(&1 + 1))
      |> Map.update!(:total, &(&1 + 1))
    end)
  end

  @doc """
  One keyset page of pending groups, newest-largest first.

  Returns `{groups, cursor}`; `cursor` is nil when the page is the last one.
  Pass the cursor back as `:after`. Ordering is `{file_count desc, id asc}`, so
  the biggest blast radius is decided first and the first screenful of
  decisions covers most of the library's files.
  """
  @spec page(binary(), keyword()) :: {[ImportGroup.t()], term() | nil}
  def page(library_path_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_page_size)

    groups =
      library_path_id
      |> base_query()
      |> apply_band(Keyword.get(opts, :band))
      |> apply_search(Keyword.get(opts, :q))
      |> apply_cursor(Keyword.get(opts, :after))
      |> order_by([g], desc: g.file_count, asc: g.id)
      |> limit(^(limit + 1))
      |> Repo.all()

    case Enum.split(groups, limit) do
      {page, []} -> {page, nil}
      {page, _extra} -> {page, cursor_for(List.last(page))}
    end
  end

  defp base_query(library_path_id) do
    ImportGroup
    |> where([g], g.library_path_id == ^library_path_id and g.status == "pending")
  end

  defp apply_band(query, nil), do: query
  defp apply_band(query, :all), do: query

  defp apply_band(query, :no_match), do: where(query, [g], is_nil(g.provider_id))

  defp apply_band(query, :ready) do
    where(
      query,
      [g],
      not is_nil(g.provider_id) and g.min_confidence >= ^@auto_accept_threshold
    )
  end

  defp apply_band(query, :needs_attention) do
    where(
      query,
      [g],
      not is_nil(g.provider_id) and g.min_confidence < ^@auto_accept_threshold
    )
  end

  defp apply_search(query, q) when is_binary(q) and q != "" do
    like = "%" <> escape_like(q) <> "%"

    where(
      query,
      [g],
      fragment("LOWER(?) LIKE LOWER(?) ESCAPE '\\'", g.anchor_path, ^like)
    )
  end

  defp apply_search(query, _), do: query

  # Backslash must be escaped first, or the escapes added on the next two
  # lines get escaped again. `_` is LIKE's single-character wildcard and shows
  # up constantly in release folder names, so it needs the same treatment as
  # `%`. The `ESCAPE '\'` clause above is what makes this backslash convention
  # take effect: PostgreSQL treats backslash as the implicit LIKE escape, but
  # SQLite has no escape character at all unless one is declared.
  defp escape_like(term) do
    term
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp apply_cursor(query, nil), do: query

  defp apply_cursor(query, {file_count, id}) do
    where(
      query,
      [g],
      g.file_count < ^file_count or (g.file_count == ^file_count and g.id > ^id)
    )
  end

  defp cursor_for(%ImportGroup{file_count: file_count, id: id}), do: {file_count, id}
end
