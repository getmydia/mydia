defmodule MydiaWeb.LibrarySchema.UserError do
  @moduledoc """
  One entry in a mutation payload's `userErrors`.

  A struct, not a map, so a resolver's `with` can tell a user error from any other
  `{:error, reason}` by pattern. One module so every mutation reports a failure
  the same way: a code a client can branch on, a message a person can read, and,
  when an argument caused it, that argument's path spelled the way the client
  wrote it (`["input", "qualityProfileId"]`, not `quality_profile_id`).
  """

  @enforce_keys [:code, :message]
  defstruct [:field, :code, :message]

  @type t :: %__MODULE__{field: [String.t()] | nil, code: atom(), message: String.t()}

  @doc "One user error."
  @spec new(atom(), String.t(), [String.t()] | nil) :: t()
  def new(code, message, field \\ nil),
    do: %__MODULE__{field: field, code: code, message: message}

  @doc "The error for an id that names nothing."
  @spec not_found(String.t(), [String.t()]) :: t()
  def not_found(thing, field), do: new(:not_found, "No #{thing} has that id", field)

  @doc "Casts `value` to a UUID, or returns the INVALID_INPUT error for `field`."
  @spec cast_id(term(), [String.t()]) :: {:ok, Ecto.UUID.t()} | {:error, t()}
  def cast_id(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, new(:invalid_input, "Not a valid id", field)}
    end
  end

  @doc """
  One INVALID_INPUT error per changeset message, each under `prefix` with the
  field name camelCased as the schema spells it.
  """
  @spec from_changeset(Ecto.Changeset.t(), [String.t()]) :: [t()]
  def from_changeset(%Ecto.Changeset{} = changeset, prefix) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate/1)
    |> Enum.flat_map(fn {field, messages} ->
      path = prefix ++ [camelize(field)]

      messages
      |> List.wrap()
      |> Enum.map(fn
        message when is_binary(message) -> new(:invalid_input, "#{field} #{message}", path)
        _nested -> new(:invalid_input, "#{field} is invalid", path)
      end)
    end)
  end

  # Ecto's placeholder syntax, e.g. "should be at least %{count} character(s)".
  defp interpolate({message, opts}) do
    Regex.replace(~r/%{(\w+)}/, message, fn whole, key ->
      case Enum.find(opts, fn {opt, _value} -> Atom.to_string(opt) == key end) do
        {_opt, value} -> to_string(value)
        nil -> whole
      end
    end)
  end

  defp camelize(field) do
    [first | rest] = field |> Atom.to_string() |> String.split("_")
    Enum.join([first | Enum.map(rest, &String.capitalize/1)])
  end
end
