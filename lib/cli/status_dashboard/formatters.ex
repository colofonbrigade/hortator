defmodule CLI.StatusDashboard.Formatters do
  @moduledoc """
  Shared pure formatting helpers used across dashboard sections:
  ANSI colorization, cell formatting, number formatting, and truncation.
  """

  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_blue IO.ANSI.blue()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_dim IO.ANSI.faint()
  @ansi_green IO.ANSI.green()
  @ansi_red IO.ANSI.red()
  @ansi_orange IO.ANSI.yellow()
  @ansi_yellow IO.ANSI.yellow()
  @ansi_magenta IO.ANSI.magenta()
  @ansi_gray IO.ANSI.light_black()

  def ansi_reset, do: @ansi_reset
  def ansi_bold, do: @ansi_bold
  def ansi_blue, do: @ansi_blue
  def ansi_cyan, do: @ansi_cyan
  def ansi_dim, do: @ansi_dim
  def ansi_green, do: @ansi_green
  def ansi_red, do: @ansi_red
  def ansi_orange, do: @ansi_orange
  def ansi_yellow, do: @ansi_yellow
  def ansi_magenta, do: @ansi_magenta
  def ansi_gray, do: @ansi_gray

  @spec colorize(String.t(), String.t()) :: String.t()
  def colorize(value, code) do
    "#{code}#{value}#{@ansi_reset}"
  end

  @spec format_cell(String.t(), non_neg_integer(), :left | :right) :: String.t()
  def format_cell(value, width, align \\ :left) do
    value =
      value
      |> to_string()
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> truncate_plain(width)

    case align do
      :right -> String.pad_leading(value, width)
      _ -> String.pad_trailing(value, width)
    end
  end

  @spec truncate(String.t(), non_neg_integer()) :: String.t()
  def truncate(value, max) when byte_size(value) > max do
    value |> String.slice(0, max) |> Kernel.<>("...")
  end

  def truncate(value, _max), do: value

  @spec format_count(term()) :: String.t()
  def format_count(nil), do: "0"

  def format_count(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> group_thousands()
  end

  def format_count(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {number, ""} -> group_thousands(Integer.to_string(number))
      _ -> value
    end
  end

  def format_count(value), do: to_string(value)

  @spec format_runtime_seconds(term()) :: String.t()
  def format_runtime_seconds(seconds) when is_integer(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}m #{secs}s"
  end

  def format_runtime_seconds(seconds) when is_binary(seconds), do: seconds
  def format_runtime_seconds(_), do: "0m 0s"

  @spec format_cost_usd(number()) :: String.t()
  def format_cost_usd(value) when is_number(value) and value >= 0.0 do
    :erlang.float_to_binary(value * 1.0, decimals: 4)
  end

  def format_cost_usd(_value), do: "0.0000"

  @spec group_thousands(String.t()) :: String.t()
  def group_thousands(value) when is_binary(value) do
    sign = if String.starts_with?(value, "-"), do: "-", else: ""
    unsigned = if sign == "", do: value, else: String.slice(value, 1, String.length(value) - 1)

    unsigned
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
    |> prepend(sign)
  end

  defp prepend("", value), do: value
  defp prepend(prefix, value), do: prefix <> value

  defp truncate_plain(value, width) do
    if byte_size(value) <= width do
      value
    else
      String.slice(value, 0, width - 3) <> "..."
    end
  end
end
