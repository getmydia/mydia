defmodule Mydia.Settings.CustomFormats do
  @moduledoc """
  Custom format definitions and their per-profile scores.

  Definitions come from two layers. `Mydia.Settings.CustomFormats.Manifest`
  ships built-ins in code; the `custom_formats` table holds operator-created
  formats plus overrides of a built-in. `list_all/0` is the only place that
  merge happens. Shipping built-ins in code rather than seeding them is what
  lets a later release improve a regex for every operator who has not
  explicitly edited that format.

  Per-profile meaning lives in `quality_profile_custom_formats`. A format has
  no inherent score; a profile decides whether it is worth 100 points, worth
  nothing, or grounds for refusing the release.
  """

  import Ecto.Query
  require Logger

  alias Mydia.Repo
  alias Mydia.Settings.CustomFormat
  alias Mydia.Settings.CustomFormats.Manifest
  alias Mydia.Settings.CustomFormats.Matcher
  alias Mydia.Settings.QualityProfile
  alias Mydia.Settings.QualityProfileCustomFormat

  @type format_view :: %{
          slug: String.t(),
          name: String.t(),
          description: String.t() | nil,
          patterns: [String.t()],
          builtin?: boolean(),
          overridden?: boolean()
        }

  @doc """
  Every known format, built-ins first in manifest order, then user-created ones
  by name.
  """
  @spec list_all() :: [format_view()]
  def list_all do
    rows = Repo.all(CustomFormat)
    by_slug = Map.new(rows, &{&1.slug, &1})

    builtins =
      Enum.map(Manifest.all(), fn entry ->
        case Map.get(by_slug, entry.slug) do
          nil -> view(entry, builtin?: true, overridden?: false)
          row -> view(row, builtin?: true, overridden?: true)
        end
      end)

    user =
      rows
      |> Enum.reject(&(&1.slug in Manifest.slugs()))
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&view(&1, builtin?: false, overridden?: false))

    builtins ++ user
  end

  @doc "The resolved view for `slug`, or nil."
  @spec get(String.t()) :: format_view() | nil
  def get(slug) when is_binary(slug), do: Enum.find(list_all(), &(&1.slug == slug))
  def get(_), do: nil

  @doc """
  Creates an operator-defined format. Rejects a slug that belongs to a built-in;
  editing a built-in goes through `override_builtin/2`.
  """
  @spec create_format(map()) :: {:ok, CustomFormat.t()} | {:error, Ecto.Changeset.t()}
  def create_format(attrs) do
    attrs = Map.put_new_lazy(attrs, :slug, fn -> unique_slug(Map.get(attrs, :name, "")) end)

    %CustomFormat{}
    |> CustomFormat.changeset(attrs)
    |> reject_builtin_slug()
    |> Repo.insert()
  end

  @doc "Updates an operator-defined format."
  @spec update_format(String.t(), map()) ::
          {:ok, CustomFormat.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_format(slug, attrs) do
    case Repo.get_by(CustomFormat, slug: slug) do
      nil -> {:error, :not_found}
      row -> row |> CustomFormat.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Creates or updates the override row for a built-in format.
  """
  @spec override_builtin(String.t(), map()) ::
          {:ok, CustomFormat.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def override_builtin(slug, attrs) do
    case Manifest.get(slug) do
      nil ->
        {:error, :not_found}

      entry ->
        attrs =
          attrs
          |> Map.put(:slug, slug)
          |> Map.put(:overrides_builtin, true)
          |> Map.put_new(:name, entry.name)
          |> Map.put_new(:description, entry.description)

        case Repo.get_by(CustomFormat, slug: slug) do
          nil -> %CustomFormat{} |> CustomFormat.changeset(attrs) |> Repo.insert()
          row -> row |> CustomFormat.changeset(attrs) |> Repo.update()
        end
    end
  end

  @doc "Drops the override row for a built-in, restoring the shipped definition."
  @spec reset_builtin(String.t()) :: :ok
  def reset_builtin(slug) do
    from(f in CustomFormat, where: f.slug == ^slug and f.overrides_builtin == true)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Deletes an operator-defined format and every profile assignment naming it.

  Built-ins cannot be deleted; reset them instead.
  """
  @spec delete_format(String.t()) :: :ok | {:error, :builtin}
  def delete_format(slug) do
    if slug in Manifest.slugs() do
      {:error, :builtin}
    else
      Repo.transaction(fn ->
        from(a in QualityProfileCustomFormat, where: a.format_slug == ^slug) |> Repo.delete_all()
        from(f in CustomFormat, where: f.slug == ^slug) |> Repo.delete_all()
      end)

      :ok
    end
  end

  @doc "Every assignment row for a profile."
  @spec list_assignments(QualityProfile.t()) :: [QualityProfileCustomFormat.t()]
  def list_assignments(%QualityProfile{id: id}) do
    from(a in QualityProfileCustomFormat, where: a.quality_profile_id == ^id)
    |> Repo.all()
  end

  @doc """
  Replaces a profile's assignments wholesale.

  Entries that are neither scored nor rejecting are not stored, so the table
  holds only assignments that mean something.
  """
  @spec set_assignments(QualityProfile.t(), [map()]) :: :ok | {:error, Ecto.Changeset.t()}
  def set_assignments(%QualityProfile{id: profile_id}, entries) do
    meaningful =
      Enum.filter(entries, fn e ->
        Map.get(e, :reject, false) or Map.get(e, :score, 0) != 0
      end)

    changesets =
      Enum.map(meaningful, fn e ->
        QualityProfileCustomFormat.changeset(%QualityProfileCustomFormat{}, %{
          quality_profile_id: profile_id,
          format_slug: Map.get(e, :format_slug),
          score: Map.get(e, :score, 0),
          reject: Map.get(e, :reject, false)
        })
      end)

    case Enum.find(changesets, &(not &1.valid?)) do
      nil ->
        Repo.transaction(fn ->
          from(a in QualityProfileCustomFormat, where: a.quality_profile_id == ^profile_id)
          |> Repo.delete_all()

          Enum.each(changesets, &Repo.insert!/1)
        end)

        :ok

      invalid ->
        {:error, invalid}
    end
  end

  @doc """
  The profile's scored formats, patterns already compiled, ready for
  `Mydia.Settings.CustomFormats.Matcher.score_title/2`.

  Takes a profile rather than a media item because two of the six
  `RankingOptions.build/1` call sites never see one: the back-compat entries in
  `MydiaWeb.MediaLive.Show.SearchHelpers` receive an already-resolved profile.
  """
  @spec resolve_for_profile(QualityProfile.t() | nil) :: [Matcher.compiled_format()]
  def resolve_for_profile(nil), do: []

  def resolve_for_profile(%QualityProfile{} = profile) do
    by_slug = Map.new(list_all(), &{&1.slug, &1})

    profile
    |> list_assignments()
    |> Enum.filter(&(&1.reject or &1.score != 0))
    |> Enum.flat_map(&compile_assignment(&1, by_slug))
  end

  defp compile_assignment(assignment, by_slug) do
    case Map.get(by_slug, assignment.format_slug) do
      nil ->
        Logger.warning(
          "[CustomFormats] profile references unknown format #{assignment.format_slug}; skipping"
        )

        []

      format ->
        case Matcher.compile_patterns(format.patterns) do
          {:ok, compiled} ->
            [
              %{
                slug: format.slug,
                name: format.name,
                score: assignment.score,
                reject: assignment.reject,
                patterns: compiled
              }
            ]

          {:error, message} ->
            Logger.warning(
              "[CustomFormats] format #{format.slug} has an uncompilable pattern " <>
                "(#{message}); skipping"
            )

            []
        end
    end
  end

  defp view(%CustomFormat{} = row, opts) do
    %{
      slug: row.slug,
      name: row.name,
      description: row.description,
      patterns: row.patterns,
      builtin?: Keyword.fetch!(opts, :builtin?),
      overridden?: Keyword.fetch!(opts, :overridden?)
    }
  end

  defp view(entry, opts) when is_map(entry) do
    %{
      slug: entry.slug,
      name: entry.name,
      description: Map.get(entry, :description),
      patterns: entry.patterns,
      builtin?: Keyword.fetch!(opts, :builtin?),
      overridden?: Keyword.fetch!(opts, :overridden?)
    }
  end

  defp reject_builtin_slug(changeset) do
    slug = Ecto.Changeset.get_field(changeset, :slug)
    overrides? = Ecto.Changeset.get_field(changeset, :overrides_builtin)

    if slug in Manifest.slugs() and not overrides? do
      Ecto.Changeset.add_error(changeset, :slug, "is reserved by a built-in format")
    else
      changeset
    end
  end

  defp unique_slug(name) do
    base = CustomFormat.slugify(name)
    base = if base == "", do: "format", else: base
    taken = Manifest.slugs() ++ Repo.all(from f in CustomFormat, select: f.slug)

    if base in taken do
      Enum.find_value(2..1000, fn n ->
        candidate = "#{base}-#{n}"
        if candidate not in taken, do: candidate
      end)
    else
      base
    end
  end
end
