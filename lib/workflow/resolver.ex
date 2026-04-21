defmodule Workflow.Resolver do
  @moduledoc """
  Pure helpers for resolving `$VAR` references and path/secret values from
  workflow YAML. Used during workflow loading to hand back fully-resolved
  settings after validation.
  """

  @spec resolve_secret(nil | String.t(), String.t() | nil) :: String.t() | nil
  def resolve_secret(nil, fallback), do: normalize_secret_value(fallback)

  def resolve_secret(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  @spec resolve_path(String.t(), String.t()) :: String.t()
  def resolve_path(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing -> default
      "" -> default
      path -> path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil
end
