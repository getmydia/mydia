defmodule Mydia.DB.Baseline do
  @moduledoc """
  The single authoritative definition of mydia's SQLite repo settings.

  Applied from `Mydia.Repo.init/2`, so every SQLite connection mydia opens
  carries the same settings no matter which config file started the repo.
  `config/dev.exs`, `config/test.exs`, and `config/runtime.exs` hold only
  per-environment values: the database path, the pool size, and the test
  sandbox pool.

  ## Why these are pinned rather than operator-configurable

  `journal_mode` and `default_transaction_mode` are correctness settings, not
  tuning knobs. Issue #283 was caused by deferred transactions under WAL, and
  the fix depends on both being what they are here. An operator who set
  `journal_mode: "delete"` would take that fix down without any warning.
  Issue #503 records the decision to stop offering them.
  """

  @pinned [
    journal_mode: :wal,
    synchronous: :normal,
    cache_size: -64_000,
    temp_store: :memory,
    foreign_keys: :on,
    busy_timeout: 30_000,
    timeout: 60_000,
    default_transaction_mode: :immediate
  ]

  @doc """
  The pinned settings as a keyword list.
  """
  @spec pinned() :: keyword()
  def pinned, do: @pinned

  @doc """
  Merges the pinned settings into a repo config for SQLite.
  Leaves any other adapter's config unchanged.
  """
  @spec apply_to(keyword(), module()) :: keyword()
  def apply_to(config, Ecto.Adapters.SQLite3), do: Keyword.merge(config, @pinned)
  def apply_to(config, _adapter), do: config
end
