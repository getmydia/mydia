defmodule Mydia.Health.Alerts.ObservationsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mydia.Downloads.BuiltIn.Status
  alias Mydia.Health.Alerts.Observations
  alias Mydia.Settings.LibraryPath

  @running %Status{engine: :running, vpn: :off, disk: :ok}
  @built_in_id Mydia.Settings.RuntimeConfig.build_runtime_id(:download_client, "Built-in")

  defp sources(overrides) do
    Keyword.merge(
      [
        built_in_status: fn -> nil end,
        client_status: fn -> %{"c1" => %{status: :healthy}} end,
        indexer_status: fn -> %{"i1" => %{status: :healthy}} end,
        library_paths: fn -> [] end,
        dir?: fn _ -> true end
      ],
      overrides
    )
  end

  defp gather(overrides), do: Observations.gather(sources(overrides))

  defp failing_keys(obs), do: for({k, v} <- obs, v != nil, do: k)

  test "all clear yields no failing keys" do
    obs = gather([])
    assert failing_keys(obs) == []

    for key <- [
          :built_in_blocked,
          :built_in_low_disk,
          :all_download_clients_down,
          :all_indexers_down
        ] do
      assert Map.has_key?(obs, key)
    end
  end

  test "built-in VPN down is blocked with the Status description" do
    obs = gather(built_in_status: fn -> %{@running | vpn: {:down, :vpn_down}} end)

    assert %{detail: detail, fix_path: "/admin/clients"} = obs.built_in_blocked
    assert detail == Status.describe(:vpn_down)
  end

  test "built-in connecting counts as blocked" do
    obs = gather(built_in_status: fn -> %{@running | vpn: :connecting} end)
    assert obs.built_in_blocked
  end

  test "built-in running is clear" do
    obs = gather(built_in_status: fn -> @running end)
    assert obs.built_in_blocked == nil
  end

  test "built-in not running is clear" do
    obs = gather(built_in_status: fn -> nil end)
    assert obs.built_in_blocked == nil
    assert obs.built_in_low_disk == nil
  end

  test "low disk" do
    status = %{@running | disk: {:low, %{free: "1 GB", reserve: "5 GB"}}}
    obs = gather(built_in_status: fn -> status end)

    assert %{detail: detail, fix_path: "/admin/clients"} = obs.built_in_low_disk
    assert detail =~ "1 GB"
    assert detail =~ "5 GB"
  end

  test "all clients unhealthy is fatal" do
    obs =
      gather(
        client_status: fn -> %{"a" => %{status: :unhealthy}, "b" => %{status: :unhealthy}} end
      )

    assert %{fix_path: "/admin/clients"} = obs.all_download_clients_down
  end

  test "one healthy client is not fatal" do
    obs =
      gather(client_status: fn -> %{"a" => %{status: :unhealthy}, "b" => %{status: :healthy}} end)

    assert obs.all_download_clients_down == nil
  end

  test "unknown clients are not fatal" do
    obs =
      gather(client_status: fn -> %{"a" => %{status: :unhealthy}, "b" => %{status: :unknown}} end)

    assert obs.all_download_clients_down == nil
  end

  test "no enabled clients is not fatal" do
    assert gather(client_status: fn -> %{} end).all_download_clients_down == nil

    assert gather(client_status: fn -> %{"a" => %{status: :disabled}} end).all_download_clients_down ==
             nil
  end

  test "built-in as the only client is reported once" do
    blocked = fn -> %{@running | vpn: {:down, :vpn_down}} end

    obs =
      gather(
        built_in_status: blocked,
        client_status: fn ->
          %{@built_in_id => %{status: :unhealthy}, "off" => %{status: :disabled}}
        end
      )

    assert obs.built_in_blocked
    assert obs.all_download_clients_down == nil

    obs =
      gather(
        built_in_status: blocked,
        client_status: fn -> %{"a" => %{status: :unhealthy}, "b" => %{status: :unhealthy}} end
      )

    assert obs.built_in_blocked
    assert obs.all_download_clients_down
  end

  test "a blocked built-in does not hide a single unhealthy external client" do
    obs =
      gather(
        built_in_status: fn -> %{@running | vpn: {:down, :vpn_down}} end,
        client_status: fn -> %{"external" => %{status: :unhealthy}} end
      )

    assert obs.built_in_blocked
    assert obs.all_download_clients_down
  end

  test "all indexers unhealthy is fatal, Cardigann included" do
    obs =
      gather(
        indexer_status: fn ->
          %{"i1" => %{status: :unhealthy}, "cardigann:x" => %{status: :unhealthy}}
        end
      )

    assert %{fix_path: "/admin/indexers"} = obs.all_indexers_down

    obs =
      gather(
        indexer_status: fn ->
          %{"i1" => %{status: :unhealthy}, "cardigann:x" => %{status: :healthy}}
        end
      )

    assert obs.all_indexers_down == nil
  end

  test "missing local root" do
    path = %LibraryPath{id: "lp1", path: "/nonexistent-root", disabled: false}
    obs = gather(library_paths: fn -> [path] end, dir?: fn _ -> false end)

    assert %{detail: detail, fix_path: "/admin/library-paths"} =
             obs[{:library_root_missing, "lp1"}]

    assert detail =~ "/nonexistent-root"
  end

  test "an unresponsive local root is reported as not responding" do
    path = %LibraryPath{id: "lp1", path: "/mnt/hung", disabled: false}
    obs = gather(library_paths: fn -> [path] end, dir?: fn _ -> :timeout end)

    assert %{detail: detail} = obs[{:library_root_missing, "lp1"}]
    assert detail =~ "/mnt/hung"
    assert detail =~ "not responding"
  end

  test "present local root is not reported" do
    path = %LibraryPath{id: "lp1", path: "/present", disabled: false}
    obs = gather(library_paths: fn -> [path] end, dir?: fn _ -> true end)
    refute Map.has_key?(obs, {:library_root_missing, "lp1"})
  end

  test "s3 and disabled roots are skipped" do
    paths = [
      %LibraryPath{id: "s3", path: "s3://backend/prefix", disabled: false},
      %LibraryPath{id: "off", path: "/gone", disabled: true}
    ]

    obs = gather(library_paths: fn -> paths end, dir?: fn _ -> false end)
    assert failing_keys(obs) == []
  end

  test "a raising source is treated as clear" do
    log =
      capture_log(fn ->
        obs =
          gather(
            client_status: fn -> raise "boom" end,
            indexer_status: fn -> %{"i1" => %{status: :unhealthy}} end
          )

        assert obs.all_download_clients_down == nil
        assert obs.all_indexers_down
      end)

    assert log =~ "boom"
  end
end
