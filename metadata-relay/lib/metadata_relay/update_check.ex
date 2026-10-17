defmodule MetadataRelay.UpdateCheck do
  @moduledoc """
  Mydia's update check, and the active-install count it yields.

  Each Mydia install sends `POST /update-check` about once a week (see
  `MetadataRelay.UpdateCheck.Handler`) carrying a random install id, its
  version, its CPU architecture and its database adapter. The relay answers
  with the newest release (`MetadataRelay.UpdateCheck.Releases`) and records
  the check here.

  A row is keyed by install id and ISO week, so the number of rows for a week
  is the number of distinct installs that ran that week. The caller's address
  is never stored, and the install id is generated for this purpose alone:
  Mydia sends it nowhere else, so it cannot be joined to feedback, crash
  reports or pairing.

  Mydia documents what it sends under "Update check" in
  `docs/using/reference/environment-variables.md`. Keep that page true if a
  field is added here.
  """

  import Ecto.Query

  alias MetadataRelay.Repo
  alias MetadataRelay.UpdateCheck.Record

  @doc """
  Records one check. A second check from the same install in the same week
  replaces the first, so an upgrade mid-week shows the newer version.
  """
  @spec record(map(), DateTime.t()) :: {:ok, Record.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    attrs =
      attrs
      |> Map.take(["install_id", "version", "arch", "db"])
      |> Map.merge(%{"week" => week_of(DateTime.to_date(now)), "checked_at" => now})

    %Record{}
    |> Record.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:version, :arch, :db, :checked_at]},
      conflict_target: [:install_id, :week]
    )
  end

  @doc "The Monday that starts `date`'s ISO week."
  @spec week_of(Date.t()) :: Date.t()
  def week_of(date), do: Date.beginning_of_week(date, :monday)

  @doc """
  Distinct installs per week for the latest `weeks` weeks that saw any,
  newest first.
  """
  @spec weekly_counts(pos_integer()) :: [%{week: Date.t(), installs: non_neg_integer()}]
  def weekly_counts(weeks \\ 12) do
    Repo.all(
      from(r in Record,
        group_by: r.week,
        order_by: [desc: r.week],
        limit: ^weeks,
        select: %{week: r.week, installs: count()}
      )
    )
  end

  @doc """
  Installs in `week` grouped by one of `:version`, `:arch` or `:db`, largest
  group first.
  """
  @spec breakdown(Date.t(), :version | :arch | :db) :: [{String.t(), non_neg_integer()}]
  def breakdown(week, field) when field in [:version, :arch, :db] do
    Repo.all(
      from(r in Record,
        where: r.week == ^week,
        group_by: field(r, ^field),
        order_by: [desc: count(), asc: field(r, ^field)],
        select: {field(r, ^field), count()}
      )
    )
  end
end
