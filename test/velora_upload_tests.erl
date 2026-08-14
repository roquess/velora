-module(velora_upload_tests).
-include_lib("eunit/include/eunit.hrl").

upload_roundtrip_test_() ->
    {timeout, 30, fun() ->
        {ok, _} = application:ensure_all_started(velora),
        try
            Port = velora_config:http_port(),
            Boundary = "----veloraTestBoundary",
            Payload = <<"RASTERBYTES-not-real">>,
            Body = multipart(Boundary, "scene.tif", Payload),
            CT = "multipart/form-data; boundary=" ++ Boundary,
            {ok, {{_,201,_}, _, RB}} = httpc:request(post,
                {"http://127.0.0.1:" ++ integer_to_list(Port) ++ "/uploads",
                 [], CT, Body}, [], []),
            #{<<"uri">> := Uri} = jsx:decode(list_to_binary(RB), [return_maps]),
            <<"work://", Name/binary>> = Uri,
            Path = filename:join(velora_config:work_dir(), binary_to_list(Name)),
            {ok, Got} = file:read_file(Path),
            ?assertEqual(Payload, Got)
        after application:stop(velora) end
    end}.

multipart(B, Filename, Data) ->
    iolist_to_binary([
      "--", B, "\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"", Filename, "\"\r\n",
      "Content-Type: application/octet-stream\r\n\r\n",
      Data, "\r\n",
      "--", B, "--\r\n"]).
