defmodule Trackers.Linear.Queries do
  @moduledoc """
  GraphQL operation strings used by `Trackers.Linear.Client`. Extracted to
  keep the client file focused on HTTP/auth/pagination plumbing.
  """

  @poll_query """
  query HortatorLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @issues_by_ids_query """
  query HortatorLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query HortatorLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec poll_query() :: String.t()
  def poll_query, do: @poll_query

  @spec issues_by_ids_query() :: String.t()
  def issues_by_ids_query, do: @issues_by_ids_query

  @spec viewer_query() :: String.t()
  def viewer_query, do: @viewer_query
end
