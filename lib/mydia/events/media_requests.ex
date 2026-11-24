defmodule Mydia.Events.MediaRequests do
  @moduledoc """
  Records the media request lifecycle events: created, approved and rejected.

  Each event carries the request's title, year, media type and TMDB id, plus
  who asked, who decided and any notes, so notifiers can describe the request
  without loading it.
  """

  alias Mydia.Accounts.User
  alias Mydia.Events
  alias Mydia.Media.MediaRequest

  @doc """
  Records a media_request.created event, attributed to the requester.

  The requester's display name is read from `request.requester`, so callers
  should preload it; an unloaded or missing association just omits the key.
  """
  @spec created(MediaRequest.t()) :: :ok
  def created(%MediaRequest{} = request) do
    Events.create_event_async(%{
      category: "requests",
      type: "media_request.created",
      actor_type: :user,
      actor_id: request.requester_id,
      resource_type: "media_request",
      resource_id: request.id,
      metadata:
        request
        |> request_metadata()
        |> Map.put("requester", person_name(request.requester))
        |> Map.put("requester_notes", request.requester_notes)
        |> reject_nils()
    })
  end

  @doc """
  Records a media_request.approved event.

  ## Options
    - `:approved_by` - the approving `%User{}` (nil when unknown)
    - `:auto` - true when the request was approved by auto-approval (default false)
  """
  @spec approved(MediaRequest.t(), keyword()) :: :ok
  def approved(%MediaRequest{} = request, opts \\ []) do
    approver = Keyword.get(opts, :approved_by)
    auto? = Keyword.get(opts, :auto, false)

    Events.create_event_async(%{
      category: "requests",
      type: "media_request.approved",
      actor_type: if(auto?, do: :system, else: :user),
      actor_id: if(auto?, do: "auto_approve", else: actor_id(approver)),
      resource_type: "media_request",
      resource_id: request.id,
      metadata:
        request
        |> request_metadata()
        |> Map.put("requester", person_name(request.requester))
        |> Map.put("approved_by", if(auto?, do: nil, else: person_name(approver)))
        |> Map.put("auto", auto?)
        |> Map.put("requester_notes", request.requester_notes)
        |> reject_nils()
    })
  end

  @doc """
  Records a media_request.rejected event.

  ## Options
    - `:rejected_by` - the rejecting `%User{}` (nil when unknown)
  """
  @spec rejected(MediaRequest.t(), keyword()) :: :ok
  def rejected(%MediaRequest{} = request, opts \\ []) do
    rejecter = Keyword.get(opts, :rejected_by)

    Events.create_event_async(%{
      category: "requests",
      type: "media_request.rejected",
      actor_type: :user,
      actor_id: actor_id(rejecter),
      resource_type: "media_request",
      resource_id: request.id,
      metadata:
        request
        |> request_metadata()
        |> Map.put("requester", person_name(request.requester))
        |> Map.put("approved_by", person_name(rejecter))
        |> Map.put("requester_notes", request.requester_notes)
        |> Map.put("rejection_reason", request.rejection_reason)
        |> reject_nils()
    })
  end

  defp request_metadata(%MediaRequest{} = request) do
    %{
      "title" => request.title,
      "year" => request.year,
      "media_type" => request.media_type,
      "tmdb_id" => request.tmdb_id
    }
  end

  defp person_name(%User{} = user), do: user.display_name || user.username
  defp person_name(_), do: nil

  defp actor_id(%User{id: id}), do: id
  defp actor_id(_), do: nil

  defp reject_nils(map), do: Map.reject(map, fn {_k, v} -> is_nil(v) end)
end
