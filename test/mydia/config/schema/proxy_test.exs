defmodule Mydia.Config.Schema.ProxyTest do
  use ExUnit.Case, async: true

  alias Mydia.Config.Schema.Proxy

  test "accepts http and https proxy URLs, with and without port and credentials" do
    for url <- ["http://prizrak:7890", "https://p.example.com", "http://u:p%40ss@10.0.0.2:3128"] do
      assert %{valid?: true} = Proxy.changeset(%Proxy{}, %{url: url})
    end
  end

  test "rejects unsupported schemes and hostless URLs by name" do
    for url <- ["socks5://p:1080", "prizrak:7890", "http://", "ftp://p:21"] do
      cs = Proxy.changeset(%Proxy{}, %{url: url})
      refute cs.valid?
      assert {"must be an http:// or https:// proxy URL with a host", _} = cs.errors[:url]
    end
  end

  test "nil and empty url are valid (no proxy)" do
    assert %{valid?: true} = Proxy.changeset(%Proxy{}, %{url: nil})
    assert %{valid?: true} = Proxy.changeset(%Proxy{}, %{url: ""})
  end
end
