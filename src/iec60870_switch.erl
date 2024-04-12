-module(iec60870_switch).
-include("iec60870.hrl").
-include("ft12.hrl").

-export([
  start/1
]).

-record(switch_state, {
  port,
  servers
}).

start(Options) ->
  Owner = self(),
  PID = spawn(fun() -> init_switch(Owner, Options) end),
  receive
    {ready, PID, Switch} -> Switch;
    {'EXIT', PID, Reason} -> exit(Reason)
  end.

init_switch(ServerPID, Options = #{port := PortName, address := Address}) ->
  % Succeeded to register switch port
  case iec60870_lib:try_register(list_to_atom(PortName), self()) of
    ok ->
      io:format("Switch. Register success, PID: ~p, address: ~p~n", [self(), Address]),
      process_flag(trap_exit, true),
      erlang:monitor(process, ServerPID),
      link(ServerPID),
      Port = iec60870_ft12:start_link(maps:with([port, port_options, address_size], Options)),
      ServerPID ! {ready, self(), self()},
      switch_loop(#switch_state{
        port = Port,
        servers = #{Address => ServerPID}
      });
    % Failed to register switch port.
    % Check for existing port.
    {error, failed} ->
      io:format("Switch. Already registered, PID: ~p, address: ~p~n", [self(), Address]),
      case whereis(list_to_atom(PortName)) of
        Switch when is_pid(Switch) ->
          Switch ! {add_server, self(), ServerPID, Options},
          receive
            {success, Switch} ->
              ServerPID ! {ready, self(), Switch},
              Switch;
            {error, Switch, Error} ->
              exit(Error);
            {'EXIT', Switch, Reason} ->
              exit(Reason)
          end;
        % No registered ports found
        _Error ->
          ?LOGERROR("failed to find switch"),
          exit(shutdown)
      end
  end.

switch_loop(#switch_state{
  port = Port,
  servers = Servers
} = State) ->
  io:format("Switch loop. Servers: ~p~n", [Servers]),
  receive
    % Message from the FT12
    {data, Port, Frame = #frame{address = LinkAddress}} ->
      % Checking if the link address is served by a switch
      case maps:get(LinkAddress, Servers, none) of
        none ->
          ?LOGWARNING("switch received unexpected link address: ~p", [LinkAddress]);
        ServerPID ->
          ServerPID ! {data, self(), Frame}
      end,
      switch_loop(State);

    % Handle send requests from one of the servers
    {send, ServerPID, Frame = #frame{address = LinkAddress}} ->
      % Checking if the link address is served by a switch
      case maps:get(LinkAddress, Servers, none) of
        none ->
          ?LOGWARNING("switch received unexpected link address: ~p", [LinkAddress]);
        ServerPID ->
          iec60870_ft12:send(Port, Frame);
        _Other ->
          ?LOGWARNING("switch received unexpected server PID: ~p", [ServerPID])
      end,
      switch_loop(State);

    % New server added to the switch
    {add_server, From, NewServerPID, #{address := NewLinkAddress} = _Options} ->
      io:format("Switch. Adding server. Link Address: ~p, PID: ~p~n", [NewLinkAddress, NewServerPID]),
      link(NewServerPID),
      erlang:monitor(process, NewServerPID),
      From ! {success, self()},
      switch_loop(State#switch_state{
        % PIDs are mapped through data link addresses
        servers = Servers#{NewLinkAddress => NewServerPID}
      });

    % Handling signals from the servers
    {'EXIT', DeadServer, _Reason} ->
      io:format("Switch. Exit from ~p!~n", [DeadServer]),
      switch_loop(State#switch_state{servers = remove_server(DeadServer, Servers)});
    {'DOWN', _, process, DeadServer, _Reason} ->
      io:format("Switch. Down from ~p!~n", [DeadServer]),
      switch_loop(State#switch_state{servers = remove_server(DeadServer, Servers)});

    Unexpected ->
      ?LOGWARNING("switch received unexpected message: ~p", [Unexpected]),
      switch_loop(State)
  end.

%% Remove a server PID value from the map
remove_server(TargetPID, Servers) ->
  case maps:size(Servers) > 0 of
    true ->
      TargetKey = maps:fold(
        fun(Key, Value, AccIn) ->
          case Value =:= TargetPID of
            true -> Key;
            false -> AccIn
          end
        end, null, Servers),
      maps:remove(TargetKey, Servers);
    false ->
      ?LOGWARNING("no servers left to handle, switch is shutting down"),
      exit(shutdown)
  end.


