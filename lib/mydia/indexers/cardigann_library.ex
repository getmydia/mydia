defmodule Mydia.Indexers.CardigannLibrary do
  @moduledoc """
  Library membership and enablement for Cardigann definitions.

  `in_library` records whether the user added a definition to their indexers;
  `enabled` records whether searches use it. A definition can be in the library
  and disabled, but never enabled outside it.
  """

  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Repo

  @type result :: {:ok, CardigannDefinition.t()} | {:error, Ecto.Changeset.t()}

  @doc """
  Adds a definition to the library and enables it. Config from an earlier
  membership is kept, so re-adding restores credentials.
  """
  @spec add(CardigannDefinition.t()) :: result()
  def add(%CardigannDefinition{} = definition), do: set_membership(definition, true)

  @doc """
  Removes a definition from the library, disabling it. Its config is kept in
  case it is added again.
  """
  @spec remove(CardigannDefinition.t()) :: result()
  def remove(%CardigannDefinition{} = definition), do: set_membership(definition, false)

  @doc """
  Enables a definition that is in the library.
  """
  @spec enable(CardigannDefinition.t()) :: result()
  def enable(%CardigannDefinition{} = definition), do: set_enabled(definition, true)

  @doc """
  Disables a definition, leaving it in the library.
  """
  @spec disable(CardigannDefinition.t()) :: result()
  def disable(%CardigannDefinition{} = definition), do: set_enabled(definition, false)

  defp set_membership(definition, member?) do
    definition
    |> CardigannDefinition.membership_changeset(%{in_library: member?, enabled: member?})
    |> Repo.update()
  end

  defp set_enabled(definition, enabled?) do
    definition
    |> CardigannDefinition.toggle_changeset(%{enabled: enabled?})
    |> Repo.update()
  end
end
