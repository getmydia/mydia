defmodule Mydia.DeadCode.Exemptions do
  @moduledoc """
  Rules describing dispatch the compiler graph cannot see.

  Per the quality-gate policy in `CONTRIBUTING.md`, exceptions here are RULES
  about tool blindness, expressed as predicates. They are never lists of
  findings. If the detector reports a false positive, express the reason it is
  reachable as a new predicate; do not add the module name.
  """

  @doc """
  True when `module` is reachable through a dispatcher the compiler cannot see.
  """
  @spec exempt?(module()) :: boolean()
  def exempt?(module) when is_atom(module) do
    mix_task?(module) or migration?(module) or protocol_impl?(module) or
      oban_worker?(module) or behaviour_impl?(module)
  end

  # Mix resolves `mix mydia.dead_code` to a module name at runtime.
  defp mix_task?(module) do
    module |> Atom.to_string() |> String.starts_with?("Elixir.Mix.Tasks.")
  end

  # Ecto.Migrator loads migration modules from priv/repo/migrations by path.
  defp migration?(module) do
    module |> Atom.to_string() |> String.contains?(".Repo.Migrations.")
  end

  # `defimpl` generates Protocol.Module names dispatched by the protocol.
  defp protocol_impl?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__impl__, 1)
  end

  # Oban resolves workers from the serialised job row, not from a call site.
  defp oban_worker?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__opts__, 0) and
      behaviours(module) |> Enum.member?(Oban.Worker)
  end

  # Guardian, Plug, telemetry, and the app's own behaviours dispatch callbacks
  # from the framework that owns the behaviour, so no call site exists in lib/.
  defp behaviour_impl?(module) do
    behaviours(module) != []
  end

  defp behaviours(module) do
    if Code.ensure_loaded?(module) do
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
    else
      []
    end
  rescue
    _ -> []
  end
end
