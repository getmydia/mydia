defmodule Mydia.Downloads.BuiltIn.PreflightTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.BuiltIn.Preflight

  @moduletag :tmp_dir

  test "parses the four keys", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "preflight"),
      "net_admin=ok\ntun=missing\nsplit_group=ok\nsrc_valid_mark=missing\n"
    )

    assert {:ok, %{net_admin: :ok, tun: :missing, split_group: :ok, src_valid_mark: :missing}} =
             Preflight.read(dir)
  end

  test "an absent file is :absent", %{tmp_dir: dir} do
    assert :absent = Preflight.read(dir)
  end

  test "a file that exists but cannot be read is an error, not :absent", %{tmp_dir: dir} do
    File.mkdir!(Path.join(dir, "preflight"))
    assert {:error, :eisdir} = Preflight.read(dir)
  end

  test "blocking reasons" do
    ok = %{net_admin: :ok, tun: :ok, split_group: :ok, src_valid_mark: :ok}
    assert nil == Preflight.blocking_reason(ok)
    assert :missing_net_admin == Preflight.blocking_reason(%{ok | net_admin: :missing})
    assert :missing_tun == Preflight.blocking_reason(%{ok | tun: :missing})
    assert :split_group_missing == Preflight.blocking_reason(%{ok | split_group: :missing})
  end

  test "src_valid_mark=missing alone is not blocking, and absent keys are not blocking",
       %{tmp_dir: dir} do
    File.write!(Path.join(dir, "preflight"), "net_admin=ok\ntun=ok\nsrc_valid_mark=missing\n")
    assert {:ok, map} = Preflight.read(dir)
    assert nil == Preflight.blocking_reason(map)
  end
end
