%%% @doc Capability list -> unit-norm f32 vector, compatible with the Emergence
%%% mesh (em_filter_vec): each capability is hashed with erlang:phash2/2 to a slot
%%% in [0, Dim-1], slot weights are summed, then the vector is L2-normalised.
%%% phash2 is deterministic for a given Erlang major version, so the same
%%% capabilities always map to the same slots across nodes.
-module(velora_emergence_vec).
-export([from_capabilities/1, from_capabilities/2]).

-define(DEFAULT_DIM, 64).

-spec from_capabilities([binary() | atom() | string()]) -> binary().
from_capabilities(Caps) -> from_capabilities(Caps, ?DEFAULT_DIM).

-spec from_capabilities([binary() | atom() | string()], pos_integer()) -> binary().
from_capabilities([], Dim) ->
    %% empty -> uniform unit vector (avoids an undefined-cosine zero vector)
    U = 1.0 / math:sqrt(float(Dim)),
    << <<U:32/float-little>> || _ <- lists:seq(1, Dim) >>;
from_capabilities(Caps, Dim) ->
    Slots = lists:foldl(
        fun(Cap, Acc) ->
            Idx = erlang:phash2(cap_key(Cap), Dim),
            maps:update_with(Idx, fun(W) -> W + 1.0 end, 1.0, Acc)
        end, #{}, Caps),
    Weights = [maps:get(I, Slots, 0.0) || I <- lists:seq(0, Dim - 1)],
    Norm = math:sqrt(lists:sum([W * W || W <- Weights])),
    Unit = case Norm > 0.0 of
               true  -> [W / Norm || W <- Weights];
               false -> Weights
           end,
    << <<F:32/float-little>> || F <- Unit >>.

cap_key(B) when is_binary(B) -> B;
cap_key(A) when is_atom(A)   -> atom_to_binary(A, utf8);
cap_key(L) when is_list(L)   -> list_to_binary(L).
