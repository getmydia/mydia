defmodule Mydia.Repo.ForeignKeyGuard do
  @moduledoc """
  Turns SQLite's nameless foreign key violations into changeset errors.

  `ecto_sqlite3` cannot recover which constraint failed from SQLite's error
  message, so its `to_constraints/2` maps every foreign key violation to
  `[foreign_key: nil]`. Ecto matches a changeset's declared constraints by
  name, a nil name matches nothing, and Ecto raises `Ecto.ConstraintError`
  instead of returning `{:error, changeset}`.

  Without this, any write taking a client-supplied id returns a clean error on
  PostgreSQL and raises a 500 on SQLite, which is the default adapter for
  self-hosted installs. Two id shapes land there: a malformed id, because a
  `binary_id` is TEXT on SQLite so no cast error fires, and the more common
  case of a well-formed id whose row was deleted.

  This is a strict no-op on PostgreSQL. `run/3` only handles an error that is
  both `type: :foreign_key` and `constraint: nil`, and only `ecto_sqlite3`
  produces a nil name. PostgreSQL always reports a real one, which Ecto has
  already tried and failed to match, meaning the changeset genuinely never
  declared it. That is a live bug on both adapters and stays loud.

  `Ecto.Multi` is covered, because it dispatches through the repo functions
  this wraps. `Repo.insert_all/3` is not covered and cannot be: it takes no
  changeset, so there is nothing to attach an error to, and a violation there
  still raises.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  @type action :: :insert | :update | :insert_or_update

  @doc """
  Runs `fun`, converting a nameless foreign key violation into
  `{:error, changeset}` attributed to the reference that is actually missing.

  Reraises anything it cannot attribute, so an undeclared constraint or a race
  stays as loud as it is today.
  """
  @spec run((-> result), term(), action()) :: result when result: term()
  def run(fun, subject, action) do
    fun.()
  rescue
    error in Ecto.ConstraintError ->
      case attribute(error, subject, action) do
        {:ok, changeset} ->
          {:error, changeset}

        :not_ours ->
          reraise error, __STACKTRACE__

        {:unattributable, schema, fields} ->
          Logger.warning(
            "unattributable foreign key violation on #{inspect(schema)}: every " <>
              "declared foreign key in #{inspect(fields)} resolves, so the failing " <>
              "reference is either undeclared or was deleted concurrently"
          )

          reraise error, __STACKTRACE__
      end
  end

  defp attribute(
         %Ecto.ConstraintError{type: :foreign_key, constraint: nil},
         %Ecto.Changeset{} = changeset,
         action
       ) do
    schema = changeset.data.__struct__
    declared = declared_foreign_keys(changeset, schema)

    case Enum.filter(declared, &missing?(changeset, &1)) do
      [] ->
        {:unattributable, schema, Enum.map(declared, & &1.constraint.field)}

      missing ->
        {:ok, add_errors(changeset, missing, resolve_action(action, changeset))}
    end
  end

  defp attribute(_error, _subject, _action), do: :not_ours

  # Pairs each declared foreign_key constraint with the belongs_to whose
  # owner_key it names. `no_assoc_constraint/3` also declares
  # `type: :foreign_key`, but its field is an association name with no matching
  # owner_key, so it drops out here. That is correct: delete/2 is out of scope.
  defp declared_foreign_keys(changeset, schema) do
    belongs_to =
      schema.__schema__(:associations)
      |> Enum.map(&schema.__schema__(:association, &1))
      |> Enum.filter(&match?(%Ecto.Association.BelongsTo{}, &1))
      |> Map.new(&{&1.owner_key, &1})

    changeset.constraints
    |> Enum.filter(&(&1.type == :foreign_key))
    |> Enum.flat_map(fn constraint ->
      case Map.fetch(belongs_to, constraint.field) do
        {:ok, assoc} -> [%{constraint: constraint, assoc: assoc}]
        :error -> []
      end
    end)
  end

  defp missing?(changeset, %{constraint: constraint, assoc: assoc}) do
    case Ecto.Changeset.get_field(changeset, constraint.field) do
      nil ->
        # A nil foreign key cannot violate the constraint.
        false

      value ->
        related = assoc.related
        related_key = assoc.related_key

        not Mydia.Repo.exists?(from(r in related, where: field(r, ^related_key) == ^value))
    end
  rescue
    # Unreachable on SQLite, the only adapter that reaches this module, but an
    # id the adapter cannot cast certainly does not exist.
    Ecto.Query.CastError -> true
  end

  # Rebuilt from the constraint entry itself, so the caller sees the
  # byte-identical changeset PostgreSQL would have produced, honouring any
  # custom `message:` the schema passed.
  defp add_errors(changeset, missing, action) do
    changeset =
      Enum.reduce(missing, changeset, fn %{constraint: constraint}, acc ->
        Ecto.Changeset.add_error(acc, constraint.field, constraint.error_message,
          constraint: constraint.error_type,
          constraint_name: constraint.constraint
        )
      end)

    %{changeset | action: action}
  end

  defp resolve_action(:insert_or_update, %Ecto.Changeset{data: %{__meta__: %{state: :loaded}}}),
    do: :update

  defp resolve_action(:insert_or_update, _changeset), do: :insert
  defp resolve_action(action, _changeset), do: action
end
