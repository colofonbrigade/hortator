defmodule Trackers.Linear.AdapterTest do
  use ExUnit.Case

  alias Trackers.Linear.Adapter

  defmodule FakeLinearClient do
    def fetch_candidate_issues(_settings) do
      send(self(), :fetch_candidate_issues_called)
      {:ok, [:candidate]}
    end

    def fetch_issues_by_states(_settings, states) do
      send(self(), {:fetch_issues_by_states_called, states})
      {:ok, states}
    end

    def fetch_issue_states_by_ids(_settings, issue_ids) do
      send(self(), {:fetch_issue_states_by_ids_called, issue_ids})
      {:ok, issue_ids}
    end
  end

  setup do
    previous_client = Application.get_env(:hortator, :linear_client_module)

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:hortator, :linear_client_module)
      else
        Application.put_env(:hortator, :linear_client_module, previous_client)
      end
    end)

    :ok
  end

  test "linear adapter delegates read calls to the configured client" do
    Application.put_env(:hortator, :linear_client_module, FakeLinearClient)
    settings = %{}

    assert {:ok, [:candidate]} = Adapter.fetch_candidate_issues(settings)
    assert_receive :fetch_candidate_issues_called

    assert {:ok, ["Todo"]} = Adapter.fetch_issues_by_states(settings, ["Todo"])
    assert_receive {:fetch_issues_by_states_called, ["Todo"]}

    assert {:ok, ["issue-1"]} = Adapter.fetch_issue_states_by_ids(settings, ["issue-1"])
    assert_receive {:fetch_issue_states_by_ids_called, ["issue-1"]}
  end
end
