%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2017 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_nodes).

-export([names/1, diagnostics/1, make/1, parts/1, cookie_hash/0,
         is_running/2, is_process_running/2,
         cluster_name/0, set_cluster_name/2, ensure_epmd/0,
         all_running/0]).

-include_lib("kernel/include/inet.hrl").

-define(EPMD_TIMEOUT, 30000).
-define(TCP_DIAGNOSTIC_TIMEOUT, 5000).
-define(ERROR_LOGGER_HANDLER, rabbit_error_logger_handler).

%%----------------------------------------------------------------------------
%% Specs
%%----------------------------------------------------------------------------

-spec names(string()) ->
          rabbit_types:ok_or_error2([{string(), integer()}], term()).
-spec diagnostics([node()]) -> string().
-spec make({string(), string()} | string()) -> node().
-spec parts(node() | string()) -> {string(), string()}.
-spec cookie_hash() -> string().
-spec is_running(node(), atom()) -> boolean().
-spec is_process_running(node(), atom()) -> boolean().
-spec cluster_name() -> binary().
-spec set_cluster_name(binary(), rabbit_types:username()) -> 'ok'.
-spec ensure_epmd() -> 'ok'.
-spec all_running() -> [node()].

%%----------------------------------------------------------------------------

names(Hostname) ->
    Self = self(),
    Ref = make_ref(),
    {Pid, MRef} = spawn_monitor(
                    fun () -> Self ! {Ref, net_adm:names(Hostname)} end),
    timer:exit_after(?EPMD_TIMEOUT, Pid, timeout),
    receive
        {Ref, Names}                         -> erlang:demonitor(MRef, [flush]),
                                                Names;
        {'DOWN', MRef, process, Pid, Reason} -> {error, Reason}
    end.

diagnostics(Nodes) ->
    verbose_erlang_distribution(true),
    NodeDiags = [{"~nDIAGNOSTICS~n===========~n~n"
                  "attempted to contact: ~p~n", [Nodes]}] ++
        [diagnostics_node(Node) || Node <- Nodes] ++
        current_node_details(),
    verbose_erlang_distribution(false),
    rabbit_misc:format_many(lists:flatten(NodeDiags)).

verbose_erlang_distribution(true) ->
    net_kernel:verbose(1),
    error_logger:add_report_handler(?ERROR_LOGGER_HANDLER);
verbose_erlang_distribution(false) ->
    net_kernel:verbose(0),
    error_logger:delete_report_handler(?ERROR_LOGGER_HANDLER).

current_node_details() ->
    [{"~ncurrent node details:~n- node name: ~w", [node()]},
     case init:get_argument(home) of
         {ok, [[Home]]} -> {"- home dir: ~s", [Home]};
         Other          -> {"- no home dir: ~p", [Other]}
     end,
     {"- cookie hash: ~s", [cookie_hash()]}].

diagnostics_node(Node) ->
    {Name, Host} = parts(Node),
    [{"~s:", [Node]} |
     case names(Host) of
         {error, Reason} ->
             [{"  * unable to connect to epmd (port ~s) on ~s: ~s~n",
               [epmd_port(), Host, rabbit_misc:format_inet_error(Reason)]}];
         {ok, NamePorts} ->
             [{"  * connected to epmd (port ~s) on ~s",
               [epmd_port(), Host]}] ++
                 case net_adm:ping(Node) of
                     pong -> dist_working_diagnostics(Node);
                     pang -> dist_broken_diagnostics(Name, Host, NamePorts)
                 end
     end].

epmd_port() ->
    case init:get_argument(epmd_port) of
        {ok, [[Port | _] | _]} when is_list(Port) -> Port;
        error                                     -> "4369"
    end.

dist_working_diagnostics(Node) ->
    case rabbit:is_running(Node) of
        true  -> [{"  * node ~s up, 'rabbit' application running", [Node]}];
        false -> [{"  * node ~s up, 'rabbit' application not running~n"
                   "  * running applications on ~s: ~p~n"
                   "  * suggestion: start_app on ~s",
                   [Node, Node, remote_apps(Node), Node]}]
    end.

remote_apps(Node) ->
    %% We want a timeout here because really, we don't trust the node,
    %% the last thing we want to do is hang.
    case rpc:call(Node, application, which_applications, [5000]) of
        {badrpc, _} = E -> E;
        Apps            -> [App || {App, _, _} <- Apps]
    end.

dist_broken_diagnostics(Name, Host, NamePorts) ->
    case [{N, P} || {N, P} <- NamePorts, N =:= Name] of
        [] ->
            {SelfName, SelfHost} = parts(node()),
            Others = [list_to_atom(N) || {N, _} <- NamePorts,
                                         N =/= case SelfHost of
                                                   Host -> SelfName;
                                                   _    -> never_matches
                                               end],
            OthersDiag = case Others of
                             [] -> [{"                  no other nodes on ~s",
                                     [Host]}];
                             _  -> [{"                  other nodes on ~s: ~p",
                                     [Host, Others]}]
                         end,
            [{"  * epmd reports: node '~s' not running at all", [Name]},
             OthersDiag, {"  * suggestion: start the node", []}];
        [{Name, Port}] ->
            [{"  * epmd reports node '~s' running on port ~b", [Name, Port]} |
             case diagnose_connect(Host, Port) of
                 ok ->
                     connection_succeeded_diagnostics();
                 {error, Reason} ->
                     [{"  * can't establish TCP connection, reason: ~s~n"
                       "  * suggestion: blocked by firewall?",
                       [rabbit_misc:format_inet_error(Reason)]}]
             end]
    end.

connection_succeeded_diagnostics() ->
    case gen_event:call(error_logger, ?ERROR_LOGGER_HANDLER, get_connection_report) of
        [] ->
            [{"  * TCP connection succeeded but Erlang distribution "
              "failed~n"
              "  * suggestion: hostname mismatch?~n"
              "  * suggestion: is the cookie set correctly?~n"
              "  * suggestion: is the Erlang distribution using TLS?", []}];
        Report ->
            [{"  * TCP connection succeeded but Erlang distribution "
              "failed~n", []}]
                ++ Report
    end.

diagnose_connect(Host, Port) ->
    case inet:gethostbyname(Host) of
        {ok, #hostent{h_addrtype = Family}} ->
            case gen_tcp:connect(Host, Port, [Family],
                                 ?TCP_DIAGNOSTIC_TIMEOUT) of
                {ok, Socket}   -> gen_tcp:close(Socket),
                                  ok;
                {error, _} = E -> E
            end;
        {error, _} = E ->
            E
    end.

make({Prefix, Suffix}) -> list_to_atom(lists:append([Prefix, "@", Suffix]));
make(NodeStr)          -> make(parts(NodeStr)).

parts(Node) when is_atom(Node) ->
    parts(atom_to_list(Node));
parts(NodeStr) ->
    case lists:splitwith(fun (E) -> E =/= $@ end, NodeStr) of
        {Prefix, []}     -> {_, Suffix} = parts(node()),
                            {Prefix, Suffix};
        {Prefix, Suffix} -> {Prefix, tl(Suffix)}
    end.

cookie_hash() ->
    base64:encode_to_string(erlang:md5(atom_to_list(erlang:get_cookie()))).

is_running(Node, Application) ->
    case rpc:call(Node, rabbit_misc, which_applications, []) of
        {badrpc, _} -> false;
        Apps        -> proplists:is_defined(Application, Apps)
    end.

is_process_running(Node, Process) ->
    case rpc:call(Node, erlang, whereis, [Process]) of
        {badrpc, _}      -> false;
        undefined        -> false;
        P when is_pid(P) -> true
    end.

cluster_name() ->
    rabbit_runtime_parameters:value_global(
      cluster_name, cluster_name_default()).

cluster_name_default() ->
    {ID, _} = rabbit_nodes:parts(node()),
    {ok, Host} = inet:gethostname(),
    {ok, #hostent{h_name = FQDN}} = inet:gethostbyname(Host),
    list_to_binary(atom_to_list(rabbit_nodes:make({ID, FQDN}))).

set_cluster_name(Name, Username) ->
    %% Cluster name should be binary
    BinaryName = rabbit_data_coercion:to_binary(Name),
    rabbit_runtime_parameters:set_global(cluster_name, BinaryName, Username).

ensure_epmd() ->
    {ok, Prog} = init:get_argument(progname),
    ID = rabbit_misc:random(1000000000),
    Port = open_port(
             {spawn_executable, os:find_executable(Prog)},
             [{args, ["-sname", rabbit_misc:format("epmd-starter-~b", [ID]),
                      "-noshell", "-eval", "halt()."]},
              exit_status, stderr_to_stdout, use_stdio]),
    port_shutdown_loop(Port).

port_shutdown_loop(Port) ->
    receive
        {Port, {exit_status, _Rc}} -> ok;
        {Port, _}                  -> port_shutdown_loop(Port)
    end.

all_running() -> rabbit_mnesia:cluster_nodes(running).
