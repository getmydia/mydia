defmodule Mydia.Subtitles.Provider.QuotaInfo do
  @moduledoc """
  Struct representing quota information for a subtitle provider.

  Different provider types have different quota models:

  - **Relay providers**: Unlimited quota (handled by relay service)
  - **OpenSubtitles free**: 200 downloads per day
  - **OpenSubtitles VIP**: 1000 downloads per day

  ## Fields

    * `:type` - Quota type (`:unlimited` or `:limited`)
    * `:provider_type` - Provider type (`:relay`, `:opensubtitles`, etc.)
    * `:remaining` - Remaining downloads (nil for unlimited)
    * `:total` - Total quota (nil for unlimited)
    * `:reset_at` - When quota resets (nil for unlimited)
    * `:vip` - Whether this is a VIP/premium account (default: false)

  ## Examples

      # Relay provider (unlimited)
      %QuotaInfo{
        type: :unlimited,
        provider_type: :relay
      }

      # OpenSubtitles free account
      %QuotaInfo{
        type: :limited,
        provider_type: :opensubtitles,
        remaining: 142,
        total: 200,
        reset_at: ~U[2024-01-01 00:00:00Z],
        vip: false
      }

      # OpenSubtitles VIP account
      %QuotaInfo{
        type: :limited,
        provider_type: :opensubtitles,
        remaining: 892,
        total: 1000,
        reset_at: ~U[2024-01-01 00:00:00Z],
        vip: true
      }

  """

  @type quota_type :: :unlimited | :limited
  @type provider_type :: :relay | :opensubtitles | :gestdown | :subdl

  @type t :: %__MODULE__{
          type: quota_type(),
          provider_type: provider_type(),
          remaining: integer() | nil,
          total: integer() | nil,
          reset_at: DateTime.t() | nil,
          vip: boolean()
        }

  @enforce_keys [:type, :provider_type]
  defstruct [
    :type,
    :provider_type,
    :remaining,
    :total,
    :reset_at,
    vip: false
  ]

  @doc """
  Creates an unlimited quota info struct for relay providers.

  ## Examples

      iex> unlimited(:relay)
      %QuotaInfo{type: :unlimited, provider_type: :relay, vip: false}

  """
  def unlimited(provider_type) do
    %__MODULE__{
      type: :unlimited,
      provider_type: provider_type
    }
  end

  @doc """
  Creates a limited quota info struct for providers with download limits.

  ## Parameters

    * `provider_type` - The provider type (e.g., `:opensubtitles`)
    * `remaining` - Number of downloads remaining
    * `total` - Total quota limit
    * `opts` - Additional options:
      * `:reset_at` - DateTime when quota resets
      * `:vip` - Whether this is a VIP account (default: false)

  ## Examples

      iex> limited(:opensubtitles, 142, 200, reset_at: ~U[2024-01-01 00:00:00Z])
      %QuotaInfo{
        type: :limited,
        provider_type: :opensubtitles,
        remaining: 142,
        total: 200,
        reset_at: ~U[2024-01-01 00:00:00Z],
        vip: false
      }

      iex> limited(:opensubtitles, 892, 1000, vip: true)
      %QuotaInfo{
        type: :limited,
        provider_type: :opensubtitles,
        remaining: 892,
        total: 1000,
        vip: true
      }

  """
  def limited(provider_type, remaining, total, opts \\ []) do
    %__MODULE__{
      type: :limited,
      provider_type: provider_type,
      remaining: remaining,
      total: total,
      reset_at: Keyword.get(opts, :reset_at),
      vip: Keyword.get(opts, :vip, false)
    }
  end

  @doc """
  Checks if quota is exhausted (for limited quotas).

  Returns `true` if remaining downloads is 0, `false` otherwise.
  Always returns `false` for unlimited quotas.

  ## Examples

      iex> exhausted?(%QuotaInfo{type: :unlimited})
      false

      iex> exhausted?(%QuotaInfo{type: :limited, remaining: 0})
      true

      iex> exhausted?(%QuotaInfo{type: :limited, remaining: 10})
      false

  """
  def exhausted?(%__MODULE__{type: :unlimited}), do: false
  def exhausted?(%__MODULE__{type: :limited, remaining: 0}), do: true
  def exhausted?(%__MODULE__{type: :limited}), do: false

  @doc """
  Checks if quota is running low (below 10% for limited quotas).

  Returns `true` if remaining downloads is less than 10% of total,
  `false` otherwise. Always returns `false` for unlimited quotas.

  ## Examples

      iex> low?(%QuotaInfo{type: :unlimited})
      false

      iex> low?(%QuotaInfo{type: :limited, remaining: 5, total: 200})
      true

      iex> low?(%QuotaInfo{type: :limited, remaining: 50, total: 200})
      false

  """
  def low?(%__MODULE__{type: :unlimited}), do: false

  def low?(%__MODULE__{type: :limited, remaining: remaining, total: total})
      when is_integer(remaining) and is_integer(total) and total > 0 do
    remaining / total < 0.1
  end

  def low?(%__MODULE__{type: :limited}), do: false

  @doc """
  Returns a percentage representing quota usage (for limited quotas).

  Returns a float between 0.0 and 100.0, or `nil` for unlimited quotas.

  ## Examples

      iex> usage_percent(%QuotaInfo{type: :unlimited})
      nil

      iex> usage_percent(%QuotaInfo{type: :limited, remaining: 150, total: 200})
      25.0

      iex> usage_percent(%QuotaInfo{type: :limited, remaining: 0, total: 200})
      100.0

  """
  def usage_percent(%__MODULE__{type: :unlimited}), do: nil

  def usage_percent(%__MODULE__{type: :limited, remaining: remaining, total: total})
      when is_integer(remaining) and is_integer(total) and total > 0 do
    ((total - remaining) / total * 100) |> Float.round(1)
  end

  def usage_percent(%__MODULE__{type: :limited}), do: nil

  @doc """
  Converts QuotaInfo struct to a plain map for serialization.

  ## Examples

      iex> info = unlimited(:relay)
      iex> to_map(info)
      %{
        type: :unlimited,
        provider_type: :relay,
        remaining: nil,
        total: nil,
        reset_at: nil,
        vip: false
      }

  """
  def to_map(%__MODULE__{} = info) do
    %{
      type: info.type,
      provider_type: info.provider_type,
      remaining: info.remaining,
      total: info.total,
      reset_at: info.reset_at,
      vip: info.vip
    }
  end
end
