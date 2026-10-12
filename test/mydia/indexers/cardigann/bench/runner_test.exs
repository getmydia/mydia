defmodule Mydia.Indexers.Cardigann.Bench.RunnerTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Bench.Runner

  test "engine order rotates with the definition index" do
    assert Runner.rotation(0) == [:prowlarr, :elixir, :wasm]
    assert Runner.rotation(1) == [:elixir, :wasm, :prowlarr]
    assert Runner.rotation(2) == [:wasm, :prowlarr, :elixir]
    assert Runner.rotation(3) == [:prowlarr, :elixir, :wasm]
  end

  test "an empty ok result on a private definition with credentials is flagged" do
    private = %{type: "private", credentials?: true}
    assert Runner.empty_with_credentials?(private, :ok, [])
    refute Runner.empty_with_credentials?(private, :ok, [:release])
    refute Runner.empty_with_credentials?(private, {:error, :timeout}, [])
    refute Runner.empty_with_credentials?(%{private | credentials?: false}, :ok, [])
    refute Runner.empty_with_credentials?(%{type: "public", credentials?: false}, :ok, [])
  end
end
