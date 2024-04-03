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

start(#{port := PortName} = Options) ->
  case whereis(list_to_atom(PortName)) of
    Switch when is_pid(Switch) ->
      link(Switch),
      Switch ! {add_server, self(), Options},
      receive
        {ready, Switch} -> Switch;
        {error, Switch, Error} -> exit(Error);
        {'EXIT', Switch, Reason} -> exit(Reason)
      end;
    _ ->
      ServerPID = self(),
      Switch = spawn_link(fun() -> init_switch(ServerPID, Options) end),
      receive
        {ready, Switch} -> Switch;
        {'EXIT', Switch, Reason} -> exit(Reason)
      end
  end.

init_switch(ServerPID, Options = #{port := PortName, address := Address}) ->
  Port = iec60870_ft12:start_link(maps:with([port, port_options, address_size], Options)),
  ServerPID ! {ready, self()},
  erlang:register(list_to_atom(PortName), self()),
  erlang:monitor(process, ServerPID),
  switch_loop(#switch_state{
    port = Port,
    servers = #{Address => ServerPID}
  }).

switch_loop(#switch_state{
  port = Port,
  servers = Servers
} = State) ->
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
    {add_server, NewServerPID, #{address := NewLinkAddress} = _Options} ->
      erlang:monitor(process, NewServerPID),
      switch_loop(State#switch_state{
        % PIDs are mapped through data link addresses
        servers = Servers#{NewLinkAddress => NewServerPID}
      });

    % Handling signals from the servers
    {'EXIT', DeadServer, _Reason} ->
      switch_loop(State#switch_state{servers = remove_server(DeadServer, Servers)});
    {'DOWN', _, process, DeadServer, _Reason} ->
      switch_loop(State#switch_state{servers = remove_server(DeadServer, Servers)});

    Unexpected ->
      ?LOGWARNING("switch received unexpected message: ~p", [Unexpected]),
      switch_loop(State)
  end.

%% Remove a server PID value from the map
remove_server(TargetPID, Servers) when length(Servers) > 0 ->
  TargetKey = maps:fold(
    fun(Key, Value, AccIn) ->
      case Value =:= TargetPID of
        true -> Key;
        false -> AccIn
      end
    end, null, Servers),
  maps:remove(TargetKey, Servers);

%% No servers left to handle
remove_server(_TargetPID, _Servers) ->
  ?LOGWARNING("no servers to handle, switch is shutting down"),
  exit(shutdown).

