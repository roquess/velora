%%% @doc Receives a multipart raster upload, streams it to the work dir, and
%%% returns a work:// URI usable as a job source.
-module(velora_upload_h).
-export([init/2]).

init(Req0, State) ->
    case cowboy_req:method(Req0) of
        <<"POST">> ->
            case save_file(Req0) of
                {ok, Uri, Req1}    -> {ok, json(Req1, 201, #{uri => Uri}), State};
                {error, R, Req1}   -> {ok, json(Req1, 400, #{error => errbin(R)}), State}
            end;
        _ ->
            {ok, json(Req0, 405, #{error => <<"method_not_allowed">>}), State}
    end.

save_file(Req0) ->
    case cowboy_req:read_part(Req0) of
        {ok, Headers, Req1} ->
            case cow_multipart:form_data(Headers) of
                {file, _Field, Filename, _CType} ->
                    Ext  = case filename:extension(Filename) of <<>> -> ".tif"; E -> E end,
                    Name = "upload_" ++ integer_to_list(erlang:unique_integer([positive]))
                             ++ binary_to_list(iolist_to_binary(Ext)),
                    Path = filename:join(velora_config:work_dir(), Name),
                    {ok, Fd} = file:open(Path, [write, binary, raw]),
                    Req2 = stream(Req1, Fd),
                    ok = file:close(Fd),
                    {ok, list_to_binary("work://" ++ Name), Req2};
                _ ->
                    {ok, _, Req2} = cowboy_req:read_part_body(Req1),
                    save_file(Req2)
            end;
        {done, Req1} ->
            {error, no_file, Req1}
    end.

stream(Req0, Fd) ->
    case cowboy_req:read_part_body(Req0) of
        {ok, Data, Req1}   -> ok = file:write(Fd, Data), Req1;
        {more, Data, Req1} -> ok = file:write(Fd, Data), stream(Req1, Fd)
    end.

json(Req, Code, Map) ->
    cowboy_req:reply(Code, #{<<"content-type">> => <<"application/json">>},
                     jsx:encode(Map), Req).

errbin(A) when is_atom(A) -> atom_to_binary(A, utf8);
errbin(E) -> iolist_to_binary(io_lib:format("~p", [E])).
