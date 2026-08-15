#!/usr/bin/env escript
%%! -*- erlang -*-
%%%-------------------------------------------------------------------
%%% build_nif.escript
%%%
%%% Build the velora_cache Rust NIF from source and place the platform
%%% artifact at priv/velora_cache-<os>-<arch>.<ext>, mirroring how sied/rast
%%% ship per-platform NIFs.
%%%
%%% Invoked by a rebar3 pre_hooks (compile) entry. Deliberately resilient: if
%%% `cargo' is not on PATH, it prints a clear message and exits 0 so an already
%%% present prebuilt artifact is used instead (this is the build-from-source
%%% fallback that avoids the manual `cargo build' dance seen deploying to the Pi).
%%%
%%% Run from the velora app root (rebar3 sets cwd there); it locates its own
%%% crate directory relative to the script path.
%%%-------------------------------------------------------------------
main(_Args) ->
    CrateDir = filename:dirname(escript:script_name()),
    PrivDir = filename:join(filename:dirname(filename:dirname(CrateDir)), "priv"),
    {OsTag, Ext, Built} = platform(),
    ArchTag = arch_tag(),
    Target = "velora_cache-" ++ OsTag ++ "-" ++ ArchTag ++ "." ++ Ext,
    TargetPath = filename:join(PrivDir, Target),
    case find_cargo() of
        false ->
            io:format(
                "velora_cache: cargo not found on PATH; skipping NIF build.~n"
                "  A prebuilt priv/~s will be used if present.~n",
                [Target]
            ),
            halt(0);
        Cargo ->
            io:format("velora_cache: building NIF with ~s~n", [Cargo]),
            ok = filelib:ensure_dir(filename:join(PrivDir, "keep")),
            case cargo_build(Cargo, CrateDir) of
                {0, _} ->
                    Src = filename:join([CrateDir, "target", "release", Built]),
                    case filelib:is_file(Src) of
                        true ->
                            {ok, _} = file:copy(Src, TargetPath),
                            io:format("velora_cache: wrote ~s~n", [TargetPath]),
                            halt(0);
                        false ->
                            io:format(standard_error,
                                "velora_cache: expected build output ~s not found~n", [Src]),
                            halt(1)
                    end;
                {Code, Out} ->
                    io:format(standard_error,
                        "velora_cache: cargo build failed (exit ~p):~n~s~n", [Code, Out]),
                    halt(Code)
            end
    end.

platform() ->
    case os:type() of
        {win32, _}     -> {"windows", "dll", "velora_cache.dll"};
        {unix, darwin} -> {"darwin", "so", "libvelora_cache.dylib"};
        {unix, _}      -> {"linux", "so", "libvelora_cache.so"}
    end.

arch_tag() ->
    Low = string:lowercase(erlang:system_info(system_architecture)),
    case string:find(Low, "aarch64") =/= nomatch
        orelse string:find(Low, "arm64") =/= nomatch of
        true  -> "aarch64";
        false -> "x86_64"
    end.

find_cargo() ->
    case os:find_executable("cargo") of
        false ->
            %% rustup default location, in case PATH is not set up in the hook env.
            Home = case os:getenv("HOME") of false -> os:getenv("USERPROFILE"); H -> H end,
            case Home of
                false -> false;
                _ ->
                    Cand = filename:join([Home, ".cargo", "bin", "cargo"]),
                    case filelib:is_file(Cand) of
                        true  -> Cand;
                        false -> false
                    end
            end;
        Path -> Path
    end.

%% Run `cargo build --release' in CrateDir via spawn_executable (no shell, so it
%% is portable across Windows/Linux/macOS). Returns {ExitCode, Output}.
cargo_build(Cargo, CrateDir) ->
    Port = open_port(
        {spawn_executable, Cargo},
        [
            {args, ["build", "--release"]},
            {cd, CrateDir},
            exit_status,
            stderr_to_stdout,
            {line, 4096},
            hide,
            binary
        ]
    ),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, {_Eol, Line}}} -> collect(Port, [Line, <<"\n">> | Acc]);
        {Port, {data, Data}}         -> collect(Port, [Data | Acc]);
        {Port, {exit_status, Code}}  -> {Code, iolist_to_binary(lists:reverse(Acc))}
    end.
