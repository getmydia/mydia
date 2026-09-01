defmodule Mydia.Collections.Collection do
  @moduledoc """
  Schema for collections that organize media items.

  Collections can be either:
  - **Manual**: User-curated lists where items are explicitly added and can be reordered
  - **Smart**: Rule-based collections that auto-populate based on filter criteria

  ## Visibility

  - `private`: Only visible to the owner
  - `shared`: Visible to all users (admin only can create)

  ## System Collections

  Collections with `is_system: true` are automatically created (e.g., Favorites) and cannot be deleted.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type_values ~w(manual smart)
  @visibility_values ~w(private shared)
  @sort_order_values ~w(position title year added_date rating)

  # Hero icons offered for sidebar sections. Every name is verified to exist in
  # deps/heroicons/optimized/24/outline. Validating against an allowlist keeps a
  # bad value from rendering a broken icon on every page in the app, since the
  # sidebar is in the layout.
  @sidebar_icons ~w(
    hero-sparkles hero-film hero-tv hero-star hero-bolt hero-fire
    hero-globe-alt hero-face-smile hero-rocket-launch hero-squares-2x2
    hero-book-open hero-beaker
  )

  @type t :: %__MODULE__{
          id: binary(),
          name: String.t() | nil,
          description: String.t() | nil,
          type: String.t(),
          poster_path: String.t() | nil,
          sort_order: String.t(),
          smart_rules: String.t() | nil,
          visibility: String.t(),
          is_system: boolean(),
          position: integer(),
          pinned_position: integer() | nil,
          sidebar_icon: String.t() | nil,
          exclusive: boolean(),
          user: Mydia.Accounts.User.t() | Ecto.Association.NotLoaded.t(),
          collection_items:
            [Mydia.Collections.CollectionItem.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "collections" do
    field :name, :string
    field :description, :string
    field :type, :string, default: "manual"
    field :poster_path, :string
    field :sort_order, :string, default: "position"
    field :smart_rules, :string
    field :visibility, :string, default: "private"
    field :is_system, :boolean, default: false
    field :position, :integer, default: 0
    field :pinned_position, :integer
    field :sidebar_icon, :string
    field :exclusive, :boolean, default: false

    belongs_to :user, Mydia.Accounts.User
    has_many :collection_items, Mydia.Collections.CollectionItem

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a collection.
  """
  def changeset(collection, attrs) do
    collection
    |> cast(attrs, [
      :name,
      :description,
      :type,
      :poster_path,
      :sort_order,
      :smart_rules,
      :visibility,
      :position,
      :pinned_position,
      :sidebar_icon,
      :exclusive
    ])
    |> validate_required([:name, :type, :visibility])
    |> validate_inclusion(:type, @type_values)
    |> validate_inclusion(:visibility, @visibility_values)
    |> validate_inclusion(:sort_order, @sort_order_values)
    |> validate_inclusion(:sidebar_icon, @sidebar_icons, message: "is not a supported icon")
    |> validate_smart_rules()
    |> validate_pinned_section_type()
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Changeset for creating a system collection (e.g., Favorites).
  """
  def system_changeset(collection, attrs) do
    collection
    |> cast(attrs, [:name, :type, :is_system])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @type_values)
    |> put_change(:visibility, "private")
    |> put_change(:is_system, true)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Returns the list of valid type values.
  """
  def valid_types, do: @type_values

  @doc """
  Returns the list of valid visibility values.
  """
  def valid_visibility_values, do: @visibility_values

  @doc """
  Returns the list of valid sort order values.
  """
  def valid_sort_orders, do: @sort_order_values

  @doc """
  Returns the hero icon names offered for sidebar sections.
  """
  def valid_sidebar_icons, do: @sidebar_icons

  # Validates that smart_rules is valid JSON with at least one condition when type is "smart"
  defp validate_smart_rules(changeset) do
    type = get_field(changeset, :type)
    smart_rules = get_change(changeset, :smart_rules)
    existing_rules = get_field(changeset, :smart_rules)
    is_new_record = get_field(changeset, :id) == nil

    cond do
      # Smart collections require rules with at least one condition
      type == "smart" && is_binary(smart_rules) ->
        validate_smart_rules_json(changeset, smart_rules)

      # New smart collections must have rules defined
      type == "smart" && is_new_record && is_nil(smart_rules) ->
        add_error(
          changeset,
          :smart_rules,
          "smart collections require at least one rule condition"
        )

      # Existing smart collections can keep their current rules
      type == "smart" && !is_new_record && is_nil(smart_rules) && is_binary(existing_rules) ->
        changeset

      type == "manual" && not is_nil(smart_rules) ->
        add_error(changeset, :smart_rules, "should not be set for manual collections")

      true ->
        changeset
    end
  end

  # Only smart collections may be pinned as sidebar sections: pin_section/3
  # and the :section LiveView route both already guard against a manual
  # collection reaching /sections/:id, since smart_rules: nil would build an
  # unfiltered query. This is the third layer, closing off the changeset
  # itself as a way to bypass those guards.
  defp validate_pinned_section_type(changeset) do
    if get_field(changeset, :type) == "manual" and
         not is_nil(get_field(changeset, :pinned_position)) do
      add_error(changeset, :pinned_position, "only smart collections can be pinned")
    else
      changeset
    end
  end

  defp validate_smart_rules_json(changeset, smart_rules) do
    case Jason.decode(smart_rules) do
      {:ok, decoded} ->
        conditions = Map.get(decoded, "conditions", [])

        if is_list(conditions) && conditions != [] do
          changeset
        else
          add_error(
            changeset,
            :smart_rules,
            "smart collections require at least one rule condition"
          )
        end

      {:error, _} ->
        add_error(changeset, :smart_rules, "must be valid JSON")
    end
  end
end
