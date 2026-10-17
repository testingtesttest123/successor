%% Test-only discovery of the existing named registry; no host modifications.
-module(boundary_fixture_native).
-export([registry_name/0]).
registry_name() ->
    [Name] = [N || N <- registered(),
                   lists:prefix("albedo_registry$", atom_to_list(N))],
    Name.
