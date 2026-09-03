defmodule Mydia.P2p.CrashingSchema do
  @moduledoc """
  A minimal Absinthe schema whose resolvers fail in the two ways that used to
  take `Mydia.P2p.Server` down with them: a raised exception and a process exit.

  The real schema is a moving target -- whichever resolver happens to be
  unguarded today may grow a `rescue` tomorrow -- so the regression test for
  P2P crash isolation resolves against this instead. What is being pinned is
  the contract (`run_graphql/4` reports a failure rather than propagating it),
  not the fragility of any particular production resolver.
  """
  use Absinthe.Schema

  query do
    @desc "Raises, the way a resolver meeting `Exqlite.Error: Database busy` does."
    field :boom, :string do
      resolve(fn _, _, _ -> raise "resolver exploded" end)
    end

    @desc "Exits, the way a resolver whose downstream `GenServer.call` times out does."
    field :bail, :string do
      resolve(fn _, _, _ -> exit(:resolver_bailed) end)
    end

    @desc "Succeeds, so the test can tell isolation from a blanket failure."
    field :fine, :string do
      resolve(fn _, _, _ -> {:ok, "ok"} end)
    end
  end
end
