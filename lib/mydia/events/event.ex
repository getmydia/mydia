defmodule Mydia.Events.Event do
  @moduledoc """
  Schema for tracking application events, user actions, and system operations.

  Events are immutable records that provide an audit trail and activity feed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Mydia.Events.Presentation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @actor_types [:user, :system, :job]
  @severity_levels [:info, :warning, :error]

  @type t :: %__MODULE__{
          id: binary(),
          category: String.t(),
          type: String.t(),
          actor_type: atom() | nil,
          actor_id: String.t() | nil,
          resource_type: String.t() | nil,
          resource_id: binary() | nil,
          severity: atom(),
          metadata: map(),
          inserted_at: DateTime.t()
        }

  schema "events" do
    field :category, :string
    field :type, :string
    field :actor_type, Ecto.Enum, values: @actor_types
    # String type allows both UUIDs (for user actors) and descriptive identifiers
    # (for system/job actors like "media_context", "download_monitor")
    field :actor_id, :string
    field :resource_type, :string
    field :resource_id, :binary_id
    field :severity, Ecto.Enum, values: @severity_levels, default: :info
    field :metadata, Mydia.Settings.JsonMapType, default: %{}

    # Events are immutable - no updated_at
    timestamps(inserted_at: :inserted_at, updated_at: false, type: :utc_datetime)
  end

  @doc """
  Changeset for creating an event.

  Events are immutable and cannot be updated after creation.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :category,
      :type,
      :actor_type,
      :actor_id,
      :resource_type,
      :resource_id,
      :severity,
      :metadata
    ])
    |> validate_required([:category, :type])
    |> validate_format(:category, ~r/^[a-z_]+$/, message: "must be lowercase with underscores")
    |> validate_format(:type, ~r/^[a-z_]+\.[a-z_]+$/, message: "must be format: category.action")
    |> validate_registered_type()
    |> validate_actor_id()
  end

  # Only check registry membership once :type is present and well-formed. Running
  # it unconditionally makes a malformed type report "not registered" alongside
  # the format error, and create_event_async/1 logs the whole error list.
  defp validate_registered_type(changeset) do
    if Keyword.has_key?(changeset.errors, :type) do
      changeset
    else
      validate_inclusion(changeset, :type, Presentation.known_types(),
        message: "is not a registered event type; add it to Mydia.Events.Presentation"
      )
    end
  end

  # Validate that actor_id is provided when actor_type is present
  defp validate_actor_id(changeset) do
    actor_type = get_field(changeset, :actor_type)
    actor_id = get_field(changeset, :actor_id)

    if actor_type && !actor_id do
      add_error(changeset, :actor_id, "must be provided when actor_type is set")
    else
      changeset
    end
  end

  @doc """
  Returns the list of valid actor types.
  """
  def valid_actor_types, do: @actor_types

  @doc """
  Returns the list of valid severity levels.
  """
  def valid_severity_levels, do: @severity_levels
end
