defmodule Trackers.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  alias Schema.Tracker.Issue
  alias Trackers.Linear.GraphQL
  alias Trackers.Linear.Queries
  alias Trackers.Linear.ResponseDecoder

  @issue_page_size 50

  @spec fetch_candidate_issues(Trackers.Linear.Tracker.settings()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(settings) do
    project_slug = Map.get(settings, :project_slug)

    cond do
      is_nil(Map.get(settings, :api_key)) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter(settings) do
          do_fetch_by_states(settings, project_slug, Map.get(settings, :active_states, []), assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states(Trackers.Linear.Tracker.settings(), [String.t()]) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(settings, state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      project_slug = Map.get(settings, :project_slug)

      cond do
        is_nil(Map.get(settings, :api_key)) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(settings, project_slug, normalized_states, nil)
      end
    end
  end

  @doc """
  Fetch issue state for a list of issue ids, paginated.

  Options:

    * `:graphql_fun` — a 2-arity function `(query, variables) -> {:ok, body} | {:error, reason}`
      used in place of the real HTTP path. Skips assignee resolution (the viewer
      lookup requires a real endpoint) and pages through `ids` using the supplied
      fun. Used by tests that exercise pagination without hitting Linear.
  """
  @spec fetch_issue_states_by_ids(Trackers.Linear.Tracker.settings(), [String.t()], keyword()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(settings, issue_ids, opts \\ []) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case {ids, Keyword.get(opts, :graphql_fun)} do
      {[], _} ->
        {:ok, []}

      {ids, nil} ->
        with {:ok, assignee_filter} <- routing_assignee_filter(settings) do
          do_fetch_issue_states(settings, ids, assignee_filter)
        end

      {ids, graphql_fun} when is_function(graphql_fun, 2) ->
        do_fetch_issue_states_with_fun(ids, nil, graphql_fun)
    end
  end

  @spec graphql(Trackers.Linear.Tracker.settings(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def graphql(settings, query, variables \\ %{}, opts \\ []),
    do: GraphQL.graphql(settings, query, variables, opts)

  defp do_fetch_by_states(settings, project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(settings, project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_states_page(settings, project_slug, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(settings, Queries.poll_query(), %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- ResponseDecoder.decode_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case ResponseDecoder.next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(settings, project_slug, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(settings, ids, assignee_filter) do
    do_fetch_issue_states_with_fun(ids, assignee_filter, &graphql(settings, &1, &2))
  end

  defp do_fetch_issue_states_with_fun(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(Queries.issues_by_ids_query(), %{
           ids: batch_ids,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- ResponseDecoder.decode_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp routing_assignee_filter(settings) do
    case Map.get(settings, :assignee) do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(settings, assignee)
    end
  end

  defp build_assignee_filter(settings, assignee) when is_binary(assignee) do
    case ResponseDecoder.normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter(settings)

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter(settings) do
    case graphql(settings, Queries.viewer_query(), %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case ResponseDecoder.assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
