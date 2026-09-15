defmodule Mydia.PerfQueryProbe do
  @moduledoc false

  # Runs one query from a known application frame so tests can assert the
  # `caller` key Mydia.Perf.Keys derives from a real Ecto stacktrace.
  #
  # The tuple keeps the Repo call out of tail position. A tail call replaces
  # this function's frame, and the stacktrace would name the test instead.
  def count_users do
    {:ok, Mydia.Repo.aggregate(Mydia.Accounts.User, :count, stacktrace: true)}
  end
end
