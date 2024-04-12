-module(iec60870_switch).
-include("iec60870.hrl").
-include("ft12.hrl").

-export([
  start/1,
  add_server/2
]).

-record(switch_state, {
  name,
  ft12_port,
  servers
}).

start(Options) ->
  Owner = self(),
  PID = spawn(fun() -> init_switch(Owner, Options) end),
  receive
    {ready, PID, Switch} ->
      Switch;
    {error, PID, InitError} ->
      exit(InitError)
  end.

add_server( Switch, Address )->
  erlang:monitor( process, Switch ),
  Switch ! {add_server, self(), Address},
  receive
    {ok, Switch} -> ok;
    {error, Switch, Error} ->
      exit( Error );
    {'DOWN', _, process, Switch, Reason}->
      exit(Reason )
  end.

init_switch(ServerPID, #{port := PortName} = Options) ->
  RegisterName = list_to_atom(PortName),
  case catch register( RegisterName, self() ) of
    {'EXIT',_} ->
      case whereis( RegisterName ) of
        Switch when is_pid( Switch )->
          ServerPID ! {ready, self(), Switch};
        _->
          init_switch( ServerPID, Options )
      end;
    true ->
      case catch iec60870_ft12:start_link(maps:with([port, port_options, address_size], Options)) of
        {'EXIT',_} ->
          ServerPID ! {error, self(), init_serial_port_error};
        FT12_Port ->
          ServerPID ! {ready, self(), self()},
          switch_loop(#switch_state{ ft12_port = FT12_Port, servers = #{}, name = PortName } )
      end
  end.


switch_loop(#switch_state{
  name = Name,
  ft12_port = FT12_Port,
  servers = Servers
} = State) ->
  io:format("Switch loop. Servers: ~p~n", [Servers]),
  receive
    % Message from the FT12
    {data, FT12_Port, Frame = #frame{address = LinkAddress}} ->
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
          iec60870_ft12:send(FT12_Port, Frame);
        _Other ->
          ?LOGWARNING("switch received unexpected server PID: ~p", [ServerPID])
      end,
      switch_loop(State);

    % New server added to the switch
    {add_server, ServerPID, LinkAddress } ->
      io:format("Switch. Adding server. Link Address: ~p, PID: ~p~n", [LinkAddress, ServerPID]),
      erlang:monitor(process, ServerPID),
      ServerPID ! {ok, self()},
      switch_loop(State#switch_state{
        % PIDs are mapped through data link addresses
        servers = Servers#{LinkAddress => ServerPID}
      });
    {'DOWN', _, process, DeadServer, _Reason} ->
      io:format("Switch. Down from ~p!~n", [DeadServer]),
      RestServers = maps:filter(fun(_A, PID)-> PID =/= DeadServer end, Servers),
      if
        map_size( RestServers ) =:= 0 ->
          ?LOGINFO("~p stop server shared port",[ Name ]),
          exit( normal );
        true ->
          switch_loop(State#switch_state{servers = RestServers})
      end;
    Unexpected ->
      ?LOGWARNING("switch received unexpected message: ~p", [Unexpected]),
      switch_loop(State)
  end.




