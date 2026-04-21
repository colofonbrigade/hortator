%{
  configs: [
    %{
      name: "default",
      strict: false,
      checks: %{
        disabled: [
          # Disabled: we prefer fully-qualified calls for clarity at the call
          # site over mechanical aliasing. See docs/elixir_rules.md § "Module
          # aliasing" for the project convention.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
