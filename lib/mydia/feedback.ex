defmodule Mydia.Feedback do
  @moduledoc """
  Sends user feedback to the metadata relay.
  """

  alias Mydia.Feedback.Sender

  @doc """
  Returns whether the in-app feedback affordance should be shown.

  Feedback defaults on. Database failures also fall back to on so a transient
  settings issue does not silently hide the support channel.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Mydia.Settings.get_config_setting_by_key("feedback.enabled") do
      nil -> true
      setting -> parse_boolean(setting.value)
    end
  rescue
    _ -> true
  end

  @doc """
  Sends feedback with instance and application metadata attached.
  """
  @spec send(map()) :: {:ok, %{id: String.t()}} | {:error, term()}
  def send(attrs) when is_map(attrs) do
    attrs
    |> normalize_attrs()
    |> Map.merge(%{
      instance_id: instance_id(),
      mydia_version: Mydia.System.app_version()
    })
    |> Sender.post()
  end

  defp normalize_attrs(attrs) do
    %{
      type: get_attr(attrs, :type),
      message: get_attr(attrs, :message),
      contact: get_attr(attrs, :contact)
    }
  end

  defp get_attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp instance_id do
    case Mydia.RemoteAccess.get_config() do
      nil -> nil
      config -> config.instance_id
    end
  end

  defp parse_boolean("true"), do: true
  defp parse_boolean("1"), do: true
  defp parse_boolean("yes"), do: true
  defp parse_boolean("on"), do: true
  defp parse_boolean(_), do: false
end
