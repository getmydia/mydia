defmodule Mydia.LibraryApi.RevisionClockBootstrap do
  @moduledoc """
  Runs the UTC-day revision clock catch-up once, synchronously, at boot.

  `Mydia.Jobs.LibraryRevisionClock` handles the ordinary case five minutes after
  midnight, but a node that was down at the boundary never runs that tick. This
  child is the recovery path: it sits after `Ecto.Migrator` and
  `Mydia.Config.Bootstrap` — so `library_revision_clock` exists and the runtime
  config is merged — and before `MydiaWeb.Endpoint`, so no request can be served
  against a stale revision feed.

  ## Failure policy

  A failed catch-up raises, which stops the child and therefore the whole
  supervision tree. This mirrors `Mydia.Config.Bootstrap`'s shape (synchronous
  `init/1`, `skip: true` returns `:ignore`) but inverts its failure policy
  deliberately: an unmerged config layer degrades an instance an operator can
  still repair from inside, while an unadvanced clock silently serves stale
  availability forever. Failing closed is the safer default.

  ## Test gate

  `skip: true` is how the test environment opts out. The sweep opens a
  transaction on the supervisor's own process, which owns no SQL Sandbox
  connection, so running it under `mix test` raises `DBConnection.OwnershipError`
  before a single test starts. `Mydia.Application.children/1` passes
  `skip: skip_revision_clock?()`.
  """

  use GenServer

  require Logger

  alias Mydia.LibraryApi.RevisionClock

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    unless Keyword.get(opts, :skip, false) do
      run(Keyword.delete(opts, :skip))
    end

    :ignore
  end

  @doc """
  Runs the catch-up sweep, returning `{:ok, marked_count}`.

  Raises when the sweep returns an error, so the supervisor fails to start the
  child and the boot stops. The `:catch_up` option overrides the sweep function
  for tests.
  """
  @spec run(keyword()) :: {:ok, non_neg_integer()}
  def run(opts \\ []) do
    catch_up = Keyword.get(opts, :catch_up, &RevisionClock.catch_up/0)

    case catch_up.() do
      {:ok, marked} ->
        Logger.info(
          "Advanced the library revision clock at startup, marked #{marked} media item(s)"
        )

        {:ok, marked}

      {:error, reason} ->
        raise "Library revision clock catch-up failed at startup: #{inspect(reason)}"
    end
  end
end
