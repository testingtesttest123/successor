# Independent P0 fixture consumer

This test-only application depends on the materialized Albedo host, never on
Successor. Its entrypoint dispatches offline storage commands before reading
fixture mode or constructing extension declarations. Initializer and service
effects are deferred callbacks. It exercises stock, equivalent-default, enabled,
disabled and quarantined compositions. It is not a production Successor bundle
or a published Hex package.
