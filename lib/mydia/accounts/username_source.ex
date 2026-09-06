defmodule Mydia.Accounts.UsernameSource do
  @moduledoc """
  Derives a username for an account that never chose one.

  `User.oidc_changeset/2` does not cast `:username` and the column is
  nullable, so an OIDC-provisioned account carries `username: nil` unless
  something puts one there. This module decides what that name should be and
  which tier produced it; `Mydia.Accounts.claim_username/2` does the writing.

  The tiers, best first:

    * `:idp` - the provider's `preferred_username` claim, which is what the
      operator sees in their IdP and the closest thing to a name the person
      chose.
    * `:email` - the local part of the email address.
    * `:sub` - `oidc-` plus a prefix of the subject identifier. Ugly, and it
      cannot match a media-server profile by accident, which is the point: it
      exists so that every account has some name rather than none.

  A tier whose slug comes out shorter than three characters is skipped rather
  than padded, because 3..50 is what `User.changeset/2` demands of a local
  username and the two kinds of account should not disagree about what a name
  may look like.
  """

  @type tier :: :idp | :email | :sub

  @min_length 3
  @max_length 50

  @doc """
  The longest a username may be.
  """
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  @doc """
  Returns the best available `{tier, slug}` for these attributes, or `:none`.

  Accepts a plain attrs map or a `%Mydia.Accounts.User{}`, so the login path
  and the backfill can share it. Fields are read with `Map.get/2` rather than
  the Access syntax, which structs do not implement.
  """
  @spec derive(map()) :: {tier(), String.t()} | :none
  def derive(attrs) do
    [
      {:idp, Map.get(attrs, :preferred_username)},
      {:email, local_part(Map.get(attrs, :email))},
      {:sub, sub_slug(Map.get(attrs, :oidc_sub))}
    ]
    |> Enum.find_value(:none, fn {tier, candidate} ->
      case slugify(candidate) do
        nil -> nil
        slug -> {tier, slug}
      end
    end)
  end

  @doc """
  The name to try on the given attempt. Attempt 1 is the bare slug.

  The base is truncated so that the suffix fits, because a 50-character slug
  with `-2` glued on would fail the length validation rather than resolve the
  collision it was reaching for.
  """
  @spec suffixed(String.t(), pos_integer()) :: String.t()
  def suffixed(slug, 1), do: slug

  def suffixed(slug, attempt) when attempt > 1 do
    suffix = "-" <> Integer.to_string(attempt)
    base = String.slice(slug, 0, @max_length - String.length(suffix))
    base <> suffix
  end

  @doc """
  Whether a newly derived tier should replace the stored name.

  An account with no name yet always takes one. A name with no recorded
  source was chosen locally, by `User.changeset/2` or by an operator, and is
  never overwritten. Otherwise the name only ever moves up the tiers, so an
  unchanged claim performs no write at all.
  """
  @spec upgrade?(String.t() | nil, String.t() | nil, tier()) :: boolean()
  def upgrade?(username, stored_source, tier) do
    cond do
      blank?(username) -> true
      is_nil(stored_source) -> false
      true -> rank(tier) > rank(stored_source)
    end
  end

  defp rank(:idp), do: 3
  defp rank(:email), do: 2
  defp rank(:sub), do: 1
  defp rank("idp"), do: 3
  defp rank("email"), do: 2
  defp rank("sub"), do: 1
  defp rank(_other), do: 0

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp local_part(nil), do: nil
  defp local_part(email) when is_binary(email), do: email |> String.split("@") |> List.first()
  defp local_part(_email), do: nil

  defp sub_slug(nil), do: nil
  defp sub_slug(sub) when is_binary(sub), do: "oidc-" <> String.slice(sub, 0, 8)
  defp sub_slug(_sub), do: nil

  defp slugify(nil), do: nil

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/u, "-")
    |> String.replace(~r/[-._]{2,}/, "-")
    |> String.replace(~r/^[-._]+|[-._]+$/, "")
    |> String.slice(0, @max_length)
    |> String.replace(~r/[-._]+$/, "")
    |> case do
      slug when byte_size(slug) == 0 -> nil
      slug -> if String.length(slug) >= @min_length, do: slug, else: nil
    end
  end

  defp slugify(_value), do: nil
end
