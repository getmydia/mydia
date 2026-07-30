defmodule Mydia.Downloads.EnrichedDownloadClientStateTest do
  @moduledoc """
  `client_config_state` distinguishes three situations that used to collapse
  into one wrong error message: the client is present, the client is merely
  disabled, and the client is gone entirely.
  """
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Structs.EnrichedDownload

  describe "client config fields" do
    test "defaults both fields to nil" do
      enriched =
        EnrichedDownload.new(%{
          id: "d-1",
          title: "Some.Release",
          download_client: "qbit",
          status: "downloading"
        })

      assert enriched.client_config_state == nil
      assert enriched.adoptable_client == nil
    end

    test "carries a removed state with no adoption candidate" do
      enriched =
        EnrichedDownload.new(%{
          id: "d-2",
          title: "Some.Release",
          download_client: "qbit-old",
          status: "missing",
          client_config_state: :removed
        })

      assert enriched.client_config_state == :removed
      assert enriched.adoptable_client == nil
    end

    test "carries a disabled state distinctly from a removed one" do
      enriched =
        EnrichedDownload.new(%{
          id: "d-3",
          title: "Some.Release",
          download_client: "qbit-paused",
          status: "missing",
          client_config_state: :disabled
        })

      assert enriched.client_config_state == :disabled
    end

    test "carries an adoption candidate alongside a removed state" do
      enriched =
        EnrichedDownload.new(%{
          id: "d-4",
          title: "Some.Release",
          download_client: "qbit-old",
          status: "downloading",
          client_config_state: :removed,
          adoptable_client: "qbit-new"
        })

      assert enriched.adoptable_client == "qbit-new"
      assert enriched.status == "downloading"
    end
  end
end
