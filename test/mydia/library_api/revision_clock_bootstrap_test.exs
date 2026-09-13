defmodule Mydia.LibraryApi.RevisionClockBootstrapTest do
  @moduledoc """
  The synchronous startup catch-up child.

  Like `Mydia.Config.Bootstrap`, it does its work in `init/1` and returns
  `:ignore`, so no process lingers. Unlike that child, a failure must stop the
  boot: a node that cannot advance the clock has lost the only chance to
  reconcile a day of availability transitions, and continuing would serve a
  stale Library API forever.
  """

  use ExUnit.Case, async: false

  alias Mydia.LibraryApi.RevisionClockBootstrap

  describe "startup" do
    test "skip: true returns :ignore without touching the database" do
      assert :ignore = RevisionClockBootstrap.start_link(skip: true)
    end

    test "a catch-up error fails startup closed" do
      # The child is linked, and init/1 raising makes GenServer.start_link both
      # return {:error, reason} and signal the caller's link. Trap the exit so
      # the assertion observes the return value instead of dying with the child.
      Process.flag(:trap_exit, true)

      assert {:error, _reason} =
               RevisionClockBootstrap.start_link(catch_up: fn -> {:error, :forced} end)
    end
  end
end
