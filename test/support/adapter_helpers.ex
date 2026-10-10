defmodule Mydia.AdapterHelpers do
  @moduledoc """
  Adapter-dependent choices for tests that must run on both SQLite and
  PostgreSQL.

  `Mydia.Repo.__adapter__/0` resolves from the compile env, so the type checker
  knows exactly one adapter per build and flags a `case Repo.__adapter__()` with
  a clause for the other one as dead. These helpers branch in function heads
  instead, which the checker does not narrow, so a test can keep covering both
  adapters without a warning.
  """

  @doc "The Oban engine matching the repo's adapter, selected as `config/config.exs` does."
  @spec oban_engine() :: module()
  def oban_engine, do: oban_engine(Mydia.Repo.__adapter__())

  @doc false
  def oban_engine(Ecto.Adapters.Postgres), do: Oban.Engines.Basic
  def oban_engine(_adapter), do: Oban.Engines.Lite

  @doc "True when the repo is running on PostgreSQL."
  @spec postgres?() :: boolean()
  def postgres?, do: postgres?(Mydia.Repo.__adapter__())

  @doc false
  def postgres?(Ecto.Adapters.Postgres), do: true
  def postgres?(_adapter), do: false
end
