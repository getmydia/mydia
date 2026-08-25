defmodule MydiaWeb.Live.Components.TrendingDetailModalActionsTest do
  @moduledoc """
  The requests pages need their own header action cluster. Dashboard and
  Discovery must keep the default one, so the slot has to be genuinely
  optional. There is no footer; both the default actions and a caller's
  `:actions` slot render inside `#trending-detail-modal-actions` in the
  pinned header.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.Live.Components.TrendingDetailModal

  defp item do
    %SearchResult{
      provider_id: "550",
      provider: :tmdb,
      media_type: :movie,
      id: 550,
      title: "Stub Movie",
      year: 1999
    }
  end

  defp base_assigns do
    %{
      id: "detail-modal",
      item: item(),
      metadata: nil,
      loading: false,
      current_user: %{role: "admin"},
      open: true,
      libraries: [],
      picker_open: false
    }
  end

  test "renders the default header actions when no actions slot is given" do
    doc = base_assigns() |> render_component_doc()

    # Enum.to_list/1 because LazyHTML.query/2 returns a %LazyHTML{} struct,
    # not a list, so a bare list pattern can never match it.
    assert [_] =
             LazyHTML.query(
               doc,
               ~s(#trending-detail-modal-actions button[phx-click="add_to_library"])
             )
             |> Enum.to_list()
  end

  test "an actions slot replaces the default header actions" do
    doc =
      base_assigns()
      |> Map.put(:actions, [
        %{
          __slot__: :actions,
          inner_block: fn _, _ -> {:safe, ~s(<button id="request-approve"></button>)} end
        }
      ])
      |> render_component_doc()

    assert [_] =
             LazyHTML.query(doc, "#trending-detail-modal-actions #request-approve")
             |> Enum.to_list()

    assert [] = LazyHTML.query(doc, ~s(button[phx-click="add_to_library"])) |> Enum.to_list()
  end

  defp render_component_doc(assigns) do
    TrendingDetailModal
    |> render_component(assigns)
    |> LazyHTML.from_fragment()
  end
end
