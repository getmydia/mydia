defmodule Mydia.Library.ImportCandidate do
  @moduledoc "A path-keyed file discovery awaiting an ownership decision."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "import_candidates" do
    field :relative_path, :string
    field :anchor_key, :string
    field :size, :integer
    field :mtime, :utc_datetime
    field :parsed_info, Mydia.Settings.JsonMapType
    field :provider_type, :string
    field :provider_id, :string
    field :title, :string
    field :year, :integer
    field :media_type, :string
    field :confidence, :float
    field :attempts, :integer, default: 0
    field :last_error, :string
    field :next_retry_at, :utc_datetime
    field :dismissed_at, :utc_datetime
    field :discovered_at, :utc_datetime

    belongs_to :library_path, Mydia.Settings.LibraryPath

    timestamps(type: :utc_datetime)
  end

  @castable ~w(
    library_path_id relative_path anchor_key size mtime parsed_info provider_type provider_id
    title year media_type confidence attempts last_error next_retry_at dismissed_at discovered_at
  )a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(candidate, attrs) do
    candidate
    |> cast(attrs, @castable)
    |> validate_required([:library_path_id, :relative_path, :anchor_key, :discovered_at])
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:library_path_id)
    |> unique_constraint([:library_path_id, :relative_path])
  end

  @spec absolute_path(t()) :: String.t() | nil
  def absolute_path(%__MODULE__{
        relative_path: relative_path,
        library_path: %Mydia.Settings.LibraryPath{path: path}
      })
      when is_binary(relative_path) and is_binary(path),
      do: Path.join(path, relative_path)

  def absolute_path(%__MODULE__{}), do: nil

  @spec to_match(t()) :: map()
  def to_match(%__MODULE__{} = candidate) do
    %{
      provider_id: candidate.provider_id,
      provider_type: known_provider(candidate.provider_type),
      title: candidate.title,
      year: candidate.year,
      match_confidence: candidate.confidence || 1.0,
      from_local_db: false,
      parsed_info: parsed_info(candidate)
    }
  end

  defp known_provider("tmdb"), do: :tmdb
  defp known_provider("tvdb"), do: :tvdb
  defp known_provider(_), do: nil

  defp parsed_info(%__MODULE__{} = candidate) do
    stored = candidate.parsed_info || %{}

    %{
      type: if(candidate.media_type == "tv_show", do: :tv_show, else: :movie),
      season: Map.get(stored, "season"),
      episodes: Map.get(stored, "episodes") || []
    }
  end
end
