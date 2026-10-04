defmodule Mydia.Plugins.IndexSeamTest do
  # async: false: :plugin_index_opts is app-wide config. DataCase because the
  # gate records an audit event on every fetch.
  use Mydia.DataCase, async: false

  import Mydia.MinisignFixtures

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Index
  alias Mydia.Plugins.Index.{Signature, Source}

  setup do
    original = Application.get_env(:mydia, :plugin_index_opts)

    on_exit(fn ->
      if original,
        do: Application.put_env(:mydia, :plugin_index_opts, original),
        else: Application.delete_env(:mydia, :plugin_index_opts)
    end)

    bypass = Bypass.open()
    keys = keypair()

    body =
      Jason.encode!(%{
        "version" => 2,
        "name" => "Seam Plugins",
        "public_key" => keys.public,
        "plugins" => []
      })

    Bypass.stub(bypass, "GET", "/index.json", &Plug.Conn.resp(&1, 200, body))
    Bypass.stub(bypass, "GET", "/index.json.minisig", &Plug.Conn.resp(&1, 200, sign(body, keys)))

    {:ok, key} = Signature.parse_public_key(keys.public)

    source = %Source{
      url: "http://allowed.test:#{bypass.port}/index.json",
      name: "Seam Plugins",
      public_key: key
    }

    %{source: source}
  end

  test "a loopback http source is refused without the seam", %{source: source} do
    Application.delete_env(:mydia, :plugin_index_opts)
    assert {:error, %Error{}} = Index.fetch_catalog(source)
  end

  test "the seam lets fetch_catalog reach it with no per-call opts", %{source: source} do
    Application.put_env(:mydia, :plugin_index_opts,
      allow_private: true,
      resolver: fn _ -> {:ok, [{127, 0, 0, 1}]} end
    )

    assert {:ok, []} = Index.fetch_catalog(source)
  end

  test "only :allow_private and :resolver pass through" do
    Application.put_env(:mydia, :plugin_index_opts, allow_private: true, max_bytes: 1)
    assert Index.seam_opts() == [allow_private: true]
  end

  test "caller opts win over the seam" do
    Application.put_env(:mydia, :plugin_index_opts, allow_private: true)
    assert Index.seam_opts(allow_private: false) == [allow_private: false]
  end
end
