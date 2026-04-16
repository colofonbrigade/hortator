defmodule Core.LogFileTest do
  use ExUnit.Case, async: true

  alias Core.LogFile

  test "default_log_file/0 uses the current working directory" do
    assert LogFile.default_log_file() == Path.join(File.cwd!(), "log/hortator.log")
  end

  test "default_log_file/1 builds the log path under a custom root" do
    assert LogFile.default_log_file("/tmp/hortator-logs") == "/tmp/hortator-logs/log/hortator.log"
  end
end
