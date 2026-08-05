defmodule Mydia.DeadCode.Exemptions do
  @moduledoc """
  Rules describing dispatch the compiler graph cannot see.

  Per the quality-gate policy in `CONTRIBUTING.md`, exceptions here are RULES
  about tool blindness, expressed as predicates. They are never lists of
  findings. If the detector reports a false positive, express the reason it is
  reachable as a new predicate; do not add the module name.
  """

  # Behaviours whose dispatcher holds no static reference anywhere in lib/.
  #
  # This is a list of dispatch CATEGORIES, not of findings. Add an entry only
  # when you can name who dispatches the behaviour and why no lib/ call site
  # exists. Task 5's audit is where new entries get justified.
  #
  # Deliberately NOT here: Phoenix.LiveView, GenServer, Plug, Ecto.Repo, and
  # every other behaviour whose implementations are referenced from lib/. A
  # wired LiveView is reachable through Router <- Endpoint <- Application, and
  # a supervised GenServer through Application's child list. Exempting them
  # would protect only the UNWIRED ones, which are precisely the dead modules
  # this tool exists to find.
  @dispatch_only_behaviours [
    # Named in mix.exs under `mod:`. Without this the supervision tree has no
    # root and the detector reports the entire application dead.
    Application,
    # Dispatched from serialised job rows and from cron entries in config/*.exs,
    # neither of which the tracer sees.
    Oban.Worker
  ]

  @doc """
  True when `module` is reachable through a dispatcher the compiler cannot see.
  """
  @spec exempt?(module()) :: boolean()
  def exempt?(module) when is_atom(module) do
    mix_task?(module) or migration?(module) or protocol_impl?(module) or
      dispatch_only_behaviour_impl?(module)
  end

  # Mix resolves `mix mydia.dead_code` to a module name at runtime.
  defp mix_task?(module) do
    module |> Atom.to_string() |> String.starts_with?("Elixir.Mix.Tasks.")
  end

  # Ecto.Migrator loads migration modules from priv/repo/migrations by path.
  defp migration?(module) do
    module |> Atom.to_string() |> String.contains?(".Repo.Migrations.")
  end

  # `defimpl` generates Protocol.Module names dispatched by the protocol at
  # runtime, so no static call site exists.
  #
  # `lib/` contains no defimpl today, so this rule currently guards an empty
  # category. It is kept because a protocol implementation genuinely has no
  # reachable call site: the first one anyone writes would otherwise be
  # reported dead. Its test uses a fixture protocol declared in the test file.
  defp protocol_impl?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :__impl__, 1)
  end

  # Implementing a behaviour confers exemption only when that behaviour's
  # dispatcher is invisible to the compiler graph. Declaring any behaviour at
  # all does not, since most behaviour implementations are referenced normally.
  defp dispatch_only_behaviour_impl?(module) do
    module
    |> behaviours()
    |> Enum.any?(&(&1 in @dispatch_only_behaviours))
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
