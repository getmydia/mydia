defmodule Mydia.P2p.ServerGraphQLTest do
  @moduledoc """
  `Mydia.P2p.Server` resolves peer GraphQL requests inside its own process, so
  an exception escaping a resolver used to kill the P2P host rather than the
  request. The supervisor then rebuilt the endpoint and every paired player was
  disconnected and had to redial, which is what an operator sees as the node
  spontaneously dropping and reconnecting. Production took three such restarts
  in one week.

  These cover `run_graphql/4`, the seam that contains such a failure. Driving it
  directly keeps the test away from the NIF resource a running host would need.
  """
  use ExUnit.Case, async: true

  alias Mydia.P2p.CrashingSchema
  alias Mydia.P2p.Server

  @context %{source: :p2p, peer_connection_type: nil}

  defp run(query), do: Server.run_graphql(query, %{}, nil, @context, CrashingSchema)

  describe "run_graphql/5" do
    test "a resolver that raises is reported, not propagated" do
      assert {:error, message} = run("query { boom }")
      assert message =~ "resolver exploded"
    end

    test "a resolver that exits is reported, not propagated" do
      assert {:error, message} = run("query { bail }")
      assert message =~ "resolver_bailed"
    end

    test "the caller survives a failing resolver" do
      # The point of the fix: the process that ran the query is still alive and
      # still answering afterwards. Before it, this second call never happened.
      assert {:error, _} = run("query { boom }")
      assert {:ok, %{data: %{"fine" => "ok"}}} = run("query { fine }")
    end

    test "a successful query is unaffected" do
      assert {:ok, %{data: %{"fine" => "ok"}}} = run("query { fine }")
    end

    test "a query the schema rejects still comes back as a GraphQL error" do
      assert {:ok, %{errors: [_ | _]}} = run("query { noSuchField }")
    end
  end
end
