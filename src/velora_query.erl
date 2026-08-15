%%% @doc Classify an Emergence query: a raster URI to render directly, or a
%%% place/topic to geocode. Pure and testable.
-module(velora_query).
-export([classify/1]).

-spec classify(binary()) -> {raster_uri, binary()} | {place, binary()} | unknown.
classify(Q) when is_binary(Q) ->
    Trimmed = string:trim(Q),
    case Trimmed of
        <<>> -> unknown;
        _ ->
            case binary:match(Trimmed, <<"://">>) of
                nomatch -> {place, Trimmed};
                _       -> {raster_uri, Trimmed}
            end
    end.
