%%% ----------------------------------------------------------------------------
%%% Copyright (c) 2009, Erlang Training and Consulting Ltd.
%%% All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%%    * Redistributions of source code must retain the above copyright
%%%      notice, this list of conditions and the following disclaimer.
%%%    * Redistributions in binary form must reproduce the above copyright
%%%      notice, this list of conditions and the following disclaimer in the
%%%      documentation and/or other materials provided with the distribution.
%%%    * Neither the name of Erlang Training and Consulting Ltd. nor the
%%%      names of its contributors may be used to endorse or promote products
%%%      derived from this software without specific prior written permission.
%%%
%%% THIS SOFTWARE IS PROVIDED BY Erlang Training and Consulting Ltd. ''AS IS''
%%% AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%%% ARE DISCLAIMED. IN NO EVENT SHALL Erlang Training and Consulting Ltd. BE
%%% LIABLE SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
%%% BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
%%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
%%% OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
%%% ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
%%% ----------------------------------------------------------------------------

%%------------------------------------------------------------------------------
%%% @author Oscar Hellstrom <oscar@hellstrom.st>
%%% @author Filipe David Manana <fdmanana@apache.org>
%%% @doc Connection manager for the HTTP client.
%%% This gen_server is responsible for keeping track of persistent
%%% connections to HTTP servers. The only interesting API is
%%% `connection_count/0' and `connection_count/1'.
%%% The gen_server is supposed to be started by a supervisor, which is
%%% normally {@link lhttpc_sup}.
%%% @end
%%------------------------------------------------------------------------------
-module(lhttpc_manager).

%% Exported functions
-export([start_link/0, start_link/1,
         client_count/1,
         connection_count/1, connection_count/2,
         queue_size/1, queue_size/2, get_connection_status/1,
         start_collect_statistic/2,
         sockets_by_host/1,
         update_connection_timeout/2,
         dump_settings/1,
         list_pools/0,
         set_max_pool_size/2,
         ensure_call/6,
         client_done/5
        ]).

%% Callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2
        ]).

-behaviour(gen_server).

-include("lhttpc_types.hrl").
-include("lhttpc.hrl").

-type host_port() :: {binary() | string(), integer(), boolean()}.%% {host, port, is_ssl}

-record(httpc_man, {
        destinations = dict:new(),
        sockets = dict:new(),
        clients = dict:new(), % Pid => {Dest, MonRef}
        queues = dict:new(),  % Dest => queue of Froms
        max_pool_size = 50 :: non_neg_integer(),
        timeout = 300000 :: non_neg_integer(),
        collect_statistic = false :: boolean(),
        connect_state = #{} :: #{host_port() => [#{client => pid(), time_start => integer()}]}
    }).

%%==============================================================================
%% Exported functions
%%==============================================================================

%%------------------------------------------------------------------------------
%% @spec (PoolPidOrName) -> list()
%% @doc Returns the current settings in state for the
%% specified lhttpc pool (manager).
%% @end
%%------------------------------------------------------------------------------
-spec dump_settings(pool_id()) -> list().
dump_settings(PidOrName) ->
    gen_server:call(PidOrName, dump_settings).

%%------------------------------------------------------------------------------
%% @doc Sets the maximum pool size for the specified pool.
%% @end
%%------------------------------------------------------------------------------
-spec set_max_pool_size(pool_id(), non_neg_integer()) -> ok.
set_max_pool_size(PidOrName, Size) when is_integer(Size), Size > 0 ->
    gen_server:cast(PidOrName, {set_max_pool_size, Size}).

%%------------------------------------------------------------------------------
%% @doc Lists all the pools already started.
%% @end
%%------------------------------------------------------------------------------
-spec list_pools() -> term().
list_pools() ->
    Children = supervisor:which_children(lhttpc_sup),
    lists:foldl(fun(In, Acc) ->
                        case In of
                            {N, P, _, [lhttpc_manager]} ->
                                [{N, dump_settings(P)} | Acc];
                            _ ->
                                Acc
                        end
                end, [], Children).

%%------------------------------------------------------------------------------
%% @spec (PoolPidOrName) -> Count
%%    Count = integer()
%% @doc Returns the total number of active clients maintained by the
%% specified lhttpc pool (manager).
%% @end
%%------------------------------------------------------------------------------
-spec client_count(pool_id()) -> non_neg_integer().
client_count(PidOrName) ->
    gen_server:call(PidOrName, client_count).

%%------------------------------------------------------------------------------
%% @spec (PoolPidOrName) -> Count
%%    Count = integer()
%% @doc Returns the total number of active connections maintained by the
%% specified lhttpc pool (manager).
%% @end
%%------------------------------------------------------------------------------
-spec connection_count(pool_id()) -> non_neg_integer().
connection_count(PidOrName) ->
    gen_server:call(PidOrName, connection_count).

%%------------------------------------------------------------------------------
%% @spec (PoolPidOrName, Destination) -> Count
%%    PoolPidOrName = pid() | atom()
%%    Destination = {Host, Port, Ssl}
%%    Host = string()
%%    Port = integer()
%%    Ssl = boolean()
%%    Count = integer()
%% @doc Returns the number of active connections to the specific
%% `Destination' maintained by the httpc manager.
%% @end
%%------------------------------------------------------------------------------
-spec connection_count(pool_id(), destination()) -> non_neg_integer().
connection_count(PidOrName, {Host, Port, Ssl}) ->
    Destination = {string:to_lower(Host), Port, Ssl},
    gen_server:call(PidOrName, {connection_count, Destination}).

%%------------------------------------------------------------------------------
%% @spec (PoolPidOrName, Destination) -> Count
%%    PoolPidOrName = pid() | atom()
%%    Count = integer()
%% @doc Returns the number of active connections to the specific
%% `Destination' maintained by the httpc manager.
%% @end
%%------------------------------------------------------------------------------
-spec sockets_by_host(pool_id()) -> [{{string(), integer()}, Count :: integer()}].
sockets_by_host(PidOrName) ->
    gen_server:call(PidOrName, sockets_by_host).


%%------------------------------------------------------------------------------
%% @spec (PoolPidOrName, Timeout) -> ok
%%    PoolPidOrName = pid() | atom()
%%    Timeout = integer()
%% @doc Updates the timeout for persistent connections.
%% This will only affect future sockets handed to the manager. The sockets
%% already managed will keep their timers.
%% @end
%%------------------------------------------------------------------------------
-spec update_connection_timeout(pool_id(), non_neg_integer()) -> ok.
update_connection_timeout(PidOrName, Milliseconds) ->
    gen_server:cast(PidOrName, {update_timeout, Milliseconds}).

%%------------------------------------------------------------------------------
%% @spec (PoolPidOrName) -> Count
%%    Count = integer()
%% @doc Returns the total size of queue clients by the
%% specified lhttpc pool (manager).
%% @end
%%------------------------------------------------------------------------------
-spec queue_size(pool_id()) -> non_neg_integer().
queue_size(PidOrName) ->
    gen_server:call(PidOrName, queue_size).

-spec queue_size(pool_id(),  destination()) -> non_neg_integer().
queue_size(PidOrName,  {Host, Port, Ssl}) ->
    Destination = {string:to_lower(Host), Port, Ssl},
    gen_server:call(PidOrName, {queue_size, Destination}).

%%------------------------------------------------------------------------------
%% @spec (PoolPidOrName) -> Count
%%    Count = integer()
%% @doc Returns the total size of queue clients by the
%% specified lhttpc pool (manager).
%% @end
%%------------------------------------------------------------------------------
-spec get_connection_status(pool_id()) -> non_neg_integer().
get_connection_status(PidOrName) ->
    gen_server:call(PidOrName, get_connection_status).

-spec start_collect_statistic(pool_id(), boolean()) -> ok.
start_collect_statistic(PidOrName, Flag) ->
    gen_server:cast(PidOrName, {start_collect_statistic, Flag}).

%%------------------------------------------------------------------------------
%% @spec () -> {ok, pid()}
%% @doc Starts and link to the gen server.
%% This is normally called by a supervisor.
%% @end
%%------------------------------------------------------------------------------
% -spec start_link() -> {ok, pid()} | {error, already_started}.
start_link() ->
    start_link([]).


%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
% -spec start_link([{atom(), non_neg_integer()}]) ->
%     {ok, pid()} | {error, already_started}.
start_link(Options0) ->
    Options = maybe_apply_defaults([connection_timeout, pool_size, collect_statistic], Options0),
    case proplists:get_value(name, Options) of
        undefined ->
            gen_server:start_link(?MODULE, Options, []);
        Name ->
            gen_server:start_link({local, Name}, ?MODULE, Options, [])
    end.

%%------------------------------------------------------------------------------
%% @doc If call contains pool_ensure option, dynamically create the pool with
%% configured parameters. Checks the pool for a socket connected to the
%% destination and returns it if it exists, 'undefined' otherwise.
%% @end
%%------------------------------------------------------------------------------
-spec ensure_call(pool_id(), pid(), host(), port_num(), boolean(), options()) ->
                        socket() | 'no_socket'.
ensure_call(Pool, Pid, Host, Port, Ssl, Options) ->
    SocketRequest = {socket, Pid, Host, Port, Ssl},
    try gen_server:call(Pool, SocketRequest, infinity) of
        {ok, S} ->
            %% Re-using HTTP/1.1 connections
            S;
        no_socket ->
            %% Opening a new HTTP/1.1 connection
            undefined
    catch
        exit:{noproc, Reason} ->
            case proplists:get_value(pool_ensure, Options, false) of
                true ->
                    {ok, DefaultTimeout} = application:get_env(
                                             lhttpc,
                                             connection_timeout),
                    ConnTimeout = proplists:get_value(pool_connection_timeout,
                                                      Options,
                                                      DefaultTimeout),
                    {ok, DefaultMaxPool} = application:get_env(
                                             lhttpc,
                                             pool_size),
                    PoolMaxSize = proplists:get_value(pool_max_size,
                                                      Options,
                                                      DefaultMaxPool),
                    case lhttpc:add_pool(Pool, ConnTimeout, PoolMaxSize) of
                        {ok, _Pid} ->
                            ensure_call(Pool, Pid, Host, Port, Ssl, Options);
                        {error, already_exists} ->
                            ensure_call(Pool, Pid, Host, Port, Ssl, Options);
                        _X ->
                            %% Failed to create pool, exit as expected
                            exit({noproc, Reason, _X})
                    end;
                false ->
                    %% No dynamic pool creation, exit as expected
                    exit({noproc, Reason})
            end
    end.

%%------------------------------------------------------------------------------
%% @doc A client has finished one request and returns the socket to the pool,
%% which can be new or not.
%% @end
%%------------------------------------------------------------------------------
-spec client_done(pid(), host(), port_num(), boolean(), socket()) -> ok.
client_done(Pool, Host, Port, Ssl, Socket) ->
    case lhttpc_sock:controlling_process(Socket, Pool, Ssl) of
        ok ->
            DoneMsg = {done, Host, Port, Ssl, Socket},
            ok = gen_server:call(Pool, DoneMsg, infinity);
        _ ->
            ok
    end.

%%==============================================================================
%% Callbacks
%%==============================================================================

%%------------------------------------------------------------------------------
%% @hidden
%%------------------------------------------------------------------------------
-spec init(any()) -> {ok, #httpc_man{}}.
init(Options) ->
    process_flag(priority, high),
    case lists:member({seed,1}, ssl:module_info(exports)) of
        true ->
            % Make sure that the ssl random number generator is seeded
            % This was new in R13 (ssl-3.10.1 in R13B vs. ssl-3.10.0 in R12B-5)
            apply(ssl, seed, [crypto:strong_rand_bytes(255)]);
        false ->
            ok
    end,
    Timeout = proplists:get_value(connection_timeout, Options),
    Size = proplists:get_value(pool_size, Options),
    CollectStats = proplists:get_value(collect_statistic, Options, false),
    {ok, #httpc_man{timeout = Timeout, max_pool_size = Size, collect_statistic = CollectStats}}.

%%------------------------------------------------------------------------------
%% @hidden
%%------------------------------------------------------------------------------
% -spec handle_call(any(), any(), #httpc_man{}) ->
%     {reply, any(), #httpc_man{}}.
handle_call({socket, Pid, Host, Port, Ssl}, {Pid, _Ref} = From, State) ->
    #httpc_man{
        max_pool_size = MaxSize,
        clients = Clients,
        queues = Queues
    } = State,
    Dest = {Host, Port, Ssl},
    {Reply0, State2} = find_socket(Dest, Pid, State),
    case Reply0 of
        {ok, _Socket} ->
            State3 = monitor_client(Dest, From, State2),
            {reply, Reply0, update_statistic(Dest, Pid, State3)};
        no_socket ->
            case dict:size(Clients) >= MaxSize of
                true ->
                    Queues2 = add_to_queue(Dest, From, Queues),
                    {noreply, State2#httpc_man{queues = Queues2}};
                false ->
                    {reply, no_socket, update_statistic(Dest, Pid, monitor_client(Dest, From, State2))}
            end
    end;
handle_call(dump_settings, _, State) ->
    {reply, [{max_pool_size, State#httpc_man.max_pool_size}, {timeout, State#httpc_man.timeout}, {collect_statistic, State#httpc_man.collect_statistic}], State};
handle_call(client_count, _, State) ->
    {reply, dict:size(State#httpc_man.clients), State};
handle_call(connection_count, _, State) ->
    {reply, dict:size(State#httpc_man.sockets), State};
handle_call(sockets_by_host, _, State) ->
    Reply = lists:map(
        fun({{Host, Port, _}, Sockets}) -> 
            {{Host, Port}, length(Sockets)}
        end, dict:to_list(State#httpc_man.destinations)),
    {reply, Reply, State};
handle_call({connection_count, Destination}, _, State) ->
    Count = case dict:find(Destination, State#httpc_man.destinations) of
        {ok, Sockets} -> length(Sockets);
        error         -> 0
    end,
    {reply, Count, State};
handle_call(queue_size, _, #httpc_man{queues = Queues} = State) ->
    Size = case Queues of
                undefined -> 0;
                _ -> lists:sum(lists:map(fun({_, Q}) -> queue:len(Q) end, dict:to_list(Queues)))
            end,
    {reply, Size, State};
handle_call({queue_size, Destination}, _, #httpc_man{queues = Queues} = State) ->
    {reply, get_queue_size_by_destination(Queues, Destination), State};
handle_call(get_connection_status, _, #httpc_man{connect_state = ConState, queues = Queues} = State) ->
    Now = erlang:system_time(millisecond),
    Reply =
        erlang:iolist_to_binary(lists:flatmap(
        fun({{Host, Port, _} = Dest, Conns}) ->
            {LeftTimes, PidCnt} = 
                lists:foldl(
                    fun({Pid, TimeStart}, {Times, Cnt}) ->
                        {[{Pid, Now - TimeStart} | Times], Cnt + 1}
                    end, {[], 0}, Conns),
            QueueSize = get_queue_size_by_destination(Queues, Dest),
            OpenSockets = 
                case dict:find(Dest, State#httpc_man.destinations) of
                    {ok, Sockets} -> length(Sockets);
                    error         -> 0
                end,
            Top10 = 
                iolist_to_binary(io_lib:format("~p", [(get_top_processes(lists:sort(fun({_, A}, {_, B}) -> A >= B end, LeftTimes), 10, []))])),
            io_lib:format("host: ~ts, port: ~w, count requests: ~w open sockets: ~w queue_size: ~w top10 oldest requests: ~s~n", [Host, Port, PidCnt, OpenSockets, QueueSize, Top10])
        end, maps:to_list(ConState))),
    {reply, binary:replace(Reply, <<"\n">>, <<10>>, [global]), State};
handle_call({done, Host, Port, Ssl, Socket}, {Pid, _} = From, State) ->
    gen_server:reply(From, ok),
    Dest = {Host, Port, Ssl},
    State2 = erase_statistic(Pid, Dest, State),
    case dict:find(Pid, State2#httpc_man.clients) of
        error ->
            {noreply, remove_socket(Socket, State2)};
        {ok, {Dest, MonRef}} ->
            true = erlang:demonitor(MonRef, [flush]),
            Clients2 = dict:erase(Pid, State2#httpc_man.clients),
            State3 = deliver_socket(Socket, Dest, State2#httpc_man{clients = Clients2}),
            {noreply, State3}
    end;
handle_call(_, _, State) ->
    {reply, {error, unknown_request}, State}.

%%------------------------------------------------------------------------------
%% @hidden
%%------------------------------------------------------------------------------
-spec handle_cast(any(), #httpc_man{}) -> {noreply, #httpc_man{}}.
handle_cast({update_timeout, Milliseconds}, State) ->
    {noreply, State#httpc_man{timeout = Milliseconds}};
handle_cast({set_max_pool_size, Size}, State) ->
    {noreply, State#httpc_man{max_pool_size = Size}};
handle_cast({start_collect_statistic, Flag}, State) ->
    {noreply, State#httpc_man{collect_statistic = Flag}};
handle_cast(_, State) ->
    {noreply, State}.

%%------------------------------------------------------------------------------
%% @hidden
%%------------------------------------------------------------------------------
-spec handle_info(any(), #httpc_man{}) -> {noreply, #httpc_man{}}.
handle_info({tcp_closed, Socket}, State) ->
    {noreply, remove_socket(Socket, State)};
handle_info({ssl_closed, Socket}, State) ->
    {noreply, remove_socket(Socket, State)};
handle_info({timeout, Socket}, State) ->
    {noreply, remove_socket(Socket, State)};
handle_info({tcp_error, Socket, _}, State) ->
    {noreply, remove_socket(Socket, State)};
handle_info({ssl_error, Socket, _}, State) ->
    {noreply, remove_socket(Socket, State)};
handle_info({tcp, Socket, _}, State) ->
    {noreply, remove_socket(Socket, State)}; % got garbage
handle_info({ssl, Socket, _}, State) ->
    {noreply, remove_socket(Socket, State)}; % got garbage
handle_info({'DOWN', MonRef, process, Pid, _Reason}, State) ->
    {Dest, MonRef} = dict:fetch(Pid, State#httpc_man.clients),
    Clients2 = dict:erase(Pid, State#httpc_man.clients),
    State2 = erase_statistic(Pid, Dest, State),
    case queue_out(Dest, State2#httpc_man.queues) of
        empty ->
            {noreply, State2#httpc_man{clients = Clients2}};
        {ok, From, Queues2} ->
            gen_server:reply(From, no_socket),
            State3 = State2#httpc_man{queues = Queues2, clients = Clients2},
            {noreply, monitor_client(Dest, From, State3)}
    end;
handle_info(_, State) ->
    {noreply, State}.

%%------------------------------------------------------------------------------
%% @hidden
%%------------------------------------------------------------------------------
-spec terminate(any(), #httpc_man{}) -> ok.
terminate(_, State) ->
    close_sockets(State#httpc_man.sockets).

%%------------------------------------------------------------------------------
%% @hidden
%%------------------------------------------------------------------------------
-spec code_change(any(), #httpc_man{}, any()) -> {'ok', #httpc_man{}}.
code_change(_, State, _) ->
    {ok, State}.

%%==============================================================================
%% Internal functions
%%==============================================================================

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
find_socket({_, _, Ssl} = Dest, Pid, State) ->
    Dests = State#httpc_man.destinations,
    case dict:find(Dest, Dests) of
        {ok, [Socket | Sockets]} ->
            lhttpc_sock:setopts(Socket, [{active, false}], Ssl),
            case lhttpc_sock:controlling_process(Socket, Pid, Ssl) of
                ok ->
                    {_, Timer} = dict:fetch(Socket, State#httpc_man.sockets),
                    cancel_timer(Timer, Socket),
                    NewState = State#httpc_man{
                        destinations = update_dest(Dest, Sockets, Dests),
                        sockets = dict:erase(Socket, State#httpc_man.sockets)
                    },
                    {{ok, Socket}, NewState};
                {error, badarg} -> % Pid has timed out, reuse for someone else
                    lhttpc_sock:setopts(Socket, [{active, once}], Ssl),
                    {no_socket, State};
                _ -> % something wrong with the socket; remove it, try again
                    find_socket(Dest, Pid, remove_socket(Socket, State))
            end;
        error ->
            {no_socket, State}
    end.

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
remove_socket(Socket, State) ->
    Dests = State#httpc_man.destinations,
    case dict:find(Socket, State#httpc_man.sockets) of
        {ok, {{_, _, Ssl} = Dest, Timer}} ->
            cancel_timer(Timer, Socket),
            lhttpc_sock:close(Socket, Ssl),
            Sockets = lists:delete(Socket, dict:fetch(Dest, Dests)),
            State#httpc_man{
                destinations = update_dest(Dest, Sockets, Dests),
                sockets = dict:erase(Socket, State#httpc_man.sockets)
            };
        error ->
            State
    end.

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
store_socket({_, _, Ssl} = Dest, Socket, State) ->
    Timeout = State#httpc_man.timeout,
    Timer = erlang:send_after(Timeout, self(), {timeout, Socket}),
    % the socket might be closed from the other side
    lhttpc_sock:setopts(Socket, [{active, once}], Ssl),
    Dests = State#httpc_man.destinations,
    Sockets = case dict:find(Dest, Dests) of
        {ok, S} -> [Socket | S];
        error   -> [Socket]
    end,
    State#httpc_man{
        destinations = dict:store(Dest, Sockets, Dests),
        sockets = dict:store(Socket, {Dest, Timer}, State#httpc_man.sockets)
    }.

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
update_dest(Destination, [], Destinations) ->
    dict:erase(Destination, Destinations);
update_dest(Destination, Sockets, Destinations) ->
    dict:store(Destination, Sockets, Destinations).

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
close_sockets(Sockets) ->
    lists:foreach(fun({Socket, {{_, _, Ssl}, Timer}}) ->
                lhttpc_sock:close(Socket, Ssl),
                erlang:cancel_timer(Timer)
        end, dict:to_list(Sockets)).

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
cancel_timer(Timer, Socket) ->
    case erlang:cancel_timer(Timer) of
        false ->
            receive
                {timeout, Socket} -> ok
            after
                0 -> ok
            end;
        _     -> ok
    end.

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
add_to_queue({_Host, _Port, _Ssl} = Dest, From, Queues) ->
    case dict:find(Dest, Queues) of
        error ->
            dict:store(Dest, queue:in(From, queue:new()), Queues);
        {ok, Q} ->
            dict:store(Dest, queue:in(From, Q), Queues)
    end.

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
queue_out({_Host, _Port, _Ssl} = Dest, Queues) ->
    case dict:find(Dest, Queues) of
        error ->
            empty;
        {ok, Q} ->
            {{value, From}, Q2} = queue:out(Q),
            Queues2 = case queue:is_empty(Q2) of
                true ->
                    dict:erase(Dest, Queues);
                false ->
                    dict:store(Dest, Q2, Queues)
            end,
            {ok, From, Queues2}
    end.

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
deliver_socket(Socket, {_, _, Ssl} = Dest, State) ->
    case queue_out(Dest, State#httpc_man.queues) of
        empty ->
            store_socket(Dest, Socket, State);
        {ok, {PidWaiter, _} = FromWaiter, Queues2} ->
            lhttpc_sock:setopts(Socket, [{active, false}], Ssl),
            case lhttpc_sock:controlling_process(Socket, PidWaiter, Ssl) of
                ok ->
                    gen_server:reply(FromWaiter, {ok, Socket}),
                    monitor_client(Dest, FromWaiter, State#httpc_man{queues = Queues2});
                {error, badarg} -> % Pid died, reuse for someone else
                    lhttpc_sock:setopts(Socket, [{active, once}], Ssl),
                    deliver_socket(Socket, Dest, State#httpc_man{queues = Queues2});
                _ -> % Something wrong with the socket; just remove it
                    catch lhttpc_sock:close(Socket, Ssl),
                    State
            end
    end.

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
monitor_client(Dest, {Pid, _} = _From, State) ->
    MonRef = erlang:monitor(process, Pid),
    Clients2 = dict:store(Pid, {Dest, MonRef}, State#httpc_man.clients),
    State#httpc_man{clients = Clients2}.

%------------------------------------------------------------------------------
%% @private
%%------------------------------------------------------------------------------
maybe_apply_defaults([], Options) ->
    Options;
maybe_apply_defaults([OptName | Rest], Options) ->
    case proplists:is_defined(OptName, Options) of
        true ->
            maybe_apply_defaults(Rest, Options);
        false ->
            Default = application:get_env(lhttpc, OptName, undefined),
            maybe_apply_defaults(Rest, [{OptName, Default} | Options])
    end.


update_statistic(Dest, Pid, #httpc_man{collect_statistic = true, connect_state = OldState} = State) ->
    State#httpc_man{connect_state = maps:put(Dest, [get_conn_data(Pid) | maps:get(Dest, OldState, [])], OldState)};

update_statistic(_Dest, _Pid, #httpc_man{} = State) ->
    State.

get_conn_data(Pid) ->
    {Pid, erlang:system_time(millisecond)}.

erase_statistic(Pid, Dest,  #httpc_man{collect_statistic = true, connect_state = OldState} = State) ->
    case maps:take(Dest, OldState) of 
        {Value, Map2} -> 
            case lists:keydelete(Pid, 1, Value) of
                [] -> State#httpc_man{connect_state = Map2};
                Rest -> State#httpc_man{connect_state = Map2#{Dest => Rest}}
            end;
        error -> State
    end;

erase_statistic(_Pid, _Dest,  State) ->
    State.

get_queue_size_by_destination(Queues, Destination) ->
    case dict:find(Destination, Queues) of
        {ok, Sockets} -> queue:len(Sockets);
        error         -> 0
    end.

get_top_processes([], _, Acc) -> lists:reverse(Acc);
get_top_processes(_, 0, Acc) -> lists:reverse(Acc);
get_top_processes([{Pid, H} | T], Cnt, Acc) ->
    get_top_processes(T, Cnt - 1, [proc_info(Pid, H) | Acc]).

proc_info(Pid, Time) ->
    case erlang:process_info(Pid) of
        I when is_list(I) ->     
            {Pid, Time, lists:filter(
                fun({K, _V}) ->
                    lists:member(K, [dictionary, current_function, total_heap_size, links, reductions])
                end, I)};
        _ -> [Pid, Time, []]
    end.