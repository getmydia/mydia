defmodule Mydia.Config.Env.ProxyEnvTest do
  use ExUnit.Case, async: true

  alias Mydia.Config.Env.ProxyEnv

  test "reads only the Mydia-specific variables" do
    env = %{
      "MYDIA_PROXY_URL" => "http://p:1",
      "MYDIA_PROXY_BYPASS" => "a.com,b",
      "HTTP_PROXY" => "http://x:2"
    }

    assert ProxyEnv.load(&Map.get(env, &1)) == %{url: "http://p:1", bypass: "a.com,b"}
  end

  test "returns an empty map when nothing is set" do
    assert ProxyEnv.load(fn _ -> nil end) == %{}
  end
end
