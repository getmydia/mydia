defmodule Mydia.Events.Presentation.Requests do
  @moduledoc """
  Builds the `detail/1` text for the media request events
  (`media_request.created`, `.approved` and `.rejected`).

  `Mydia.Events.Presentation` keeps their registry entries and delegates the
  detail text here.
  """

  alias Mydia.Events.Event

  @types ~w(media_request.created media_request.approved media_request.rejected)

  @doc "The media request event types this module describes."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "Detail text for a media request event."
  @spec detail(Event.t()) :: String.t()
  def detail(%Event{type: "media_request.rejected", metadata: metadata}) do
    case metadata["rejection_reason"] do
      reason when is_binary(reason) and reason != "" ->
        "#{request_subject(metadata)} (reason: #{reason})"

      _ ->
        request_subject(metadata)
    end
  end

  def detail(%Event{type: type, metadata: metadata}) when type in @types,
    do: request_subject(metadata)

  # "Requester: Title (Year)", dropping the parts the metadata lacks.
  defp request_subject(metadata) do
    subject =
      case metadata["year"] do
        nil -> title_of(metadata)
        year -> "#{title_of(metadata)} (#{year})"
      end

    case metadata["requester"] do
      nil -> subject
      requester -> "#{requester}: #{subject}"
    end
  end

  defp title_of(metadata), do: metadata["title"] || "Unknown"
end
