defmodule Mydia.PluginStoreFixture do
  @moduledoc """
  A third-party plugin source served from Bypass: a minisign-signed
  `index.json` and the packages it lists.

  `publish/3` adds or replaces one plugin's entry and re-signs the catalog, so
  a test can ship a new version mid-run. The catalog body and its signature
  are computed together at publish time, so the two requests a fetch makes
  can never see different catalogs.
  """

  import Mydia.MinisignFixtures, only: [sign: 2]

  defstruct [:bypass, :keys, :name, :agent]

  def start(bypass, keys, name \\ "Lantern Plugins") do
    {:ok, agent} = Agent.start_link(fn -> %{entries: %{}, body: nil, sig: nil} end)
    store = %__MODULE__{bypass: bypass, keys: keys, name: name, agent: agent}
    :ok = sign_catalog(store)

    Bypass.stub(bypass, "GET", "/index.json", fn conn ->
      Plug.Conn.resp(conn, 200, Agent.get(agent, & &1.body))
    end)

    Bypass.stub(bypass, "GET", "/index.json.minisig", fn conn ->
      Plug.Conn.resp(conn, 200, Agent.get(agent, & &1.sig))
    end)

    store
  end

  def url(%__MODULE__{} = store), do: base_url(store) <> "/index.json"

  def publish(%__MODULE__{} = store, %{"slug" => slug, "version" => version} = manifest, wasm) do
    path = "/packages/#{slug}/#{version}.wasm"
    Bypass.stub(store.bypass, "GET", path, &Plug.Conn.resp(&1, 200, wasm))

    entry = %{
      "package_url" => base_url(store) <> path,
      "integrity" => "sha256:" <> (:crypto.hash(:sha256, wasm) |> Base.encode16(case: :lower)),
      "manifest" => manifest
    }

    Agent.update(store.agent, &put_in(&1, [:entries, slug], entry))
    sign_catalog(store)
  end

  defp sign_catalog(store) do
    Agent.update(store.agent, fn state ->
      body =
        Jason.encode!(%{
          "version" => 2,
          "name" => store.name,
          "public_key" => store.keys.public,
          "plugins" => Map.values(state.entries)
        })

      %{state | body: body, sig: sign(body, store.keys)}
    end)
  end

  defp base_url(store), do: "http://localhost:#{store.bypass.port}"
end
