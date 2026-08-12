%%% @doc Per-tile k-NN index over kvex. Feature vectors are L2-normalized output
%%% histograms; search is cosine similarity (dot product of unit vectors).
-module(velora_index).
-export([vector/1, build/2, search/3]).

-spec vector([number()]) -> [float()].
vector(Hist) ->
    unit(Hist).

-spec build(pos_integer(), [{binary(), [number()]}]) -> term().
build(Dim, Pairs) ->
    {ok, Ix} = kvex:new(Dim),
    ok = kvex:add_batch(Ix, [{Id, vector(Hist)} || {Id, Hist} <- Pairs]),
    Ix.

-spec search(term(), [number()], pos_integer()) -> [{binary(), float()}].
search(Ix, Query, K) ->
    {ok, Results} = kvex:search(Ix, unit(Query), K),
    Results.

unit(V) ->
    Fs   = [float(X) || X <- V],
    Norm = math:sqrt(lists:sum([F * F || F <- Fs])),
    if
        Norm > 0.0 -> [F / Norm || F <- Fs];
        true       -> [0.0 || _ <- Fs]
    end.
