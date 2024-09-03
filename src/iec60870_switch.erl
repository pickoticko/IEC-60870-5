%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License that can be found in the LICENSE file.                 |
%%% +----------------------------------------------------------------+

-module(iec60870_switch).

-include("iec60870.hrl").
-include("ft12.hrl").

%%% +--------------------------------------------------------------+
%%% |                             API                              |
%%% +--------------------------------------------------------------+

-export([
  start/1,
  add_server/2
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-record(switch_state, {
  name,
  port_ft12,
  servers,
  options
}).

-define(SILENT_TIMEOUT, 60000).

%%% +--------------------------------------------------------------+
%%% |                      API implementation                      |
%%% +--------------------------------------------------------------+

start(Options) ->
  Owner = self(),
  PID = spawn_link(fun() -> init_switch(Owner, Options) end),
  receive
    {ready, PID, PID} ->
      PID;
    {ready, PID, Switch} ->
      link(Switch),
      Switch
  end.

add_server(Switch, Address) ->
  Switch ! {add_server, self(), Address},
  receive {ok, Switch} -> ok end.

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init_switch(ServerPID, #{transport := #{name := PortName}} = Options) ->
  RegisterName = list_to_atom(PortName),
  case catch register(RegisterName, self()) of
    % Probably already registered
    % Check the registered PID by the port name
    {'EXIT', _} ->
      case whereis(RegisterName) of
        Switch when is_pid(Switch) ->
          ServerPID ! {ready, self(), Switch};
        _ ->
          init_switch(ServerPID, Options)
      end;
    % Succeeded to register port, start the switch
    true ->
      FT12_options = maps:with([transport, address_size], Options),
      case catch iec60870_ft12:start_link( FT12_options ) of
        {'EXIT', Error} ->
          ?LOGERROR("switch ~p failed to start transport, error: ~p", [PortName, Error]),
          exit({transport_init_fail, Error});
        PortFT12 ->
          process_flag(trap_exit, true),
          ServerPID ! {ready, self(), self()},
          switch_loop(#switch_state{port_ft12 = PortFT12, servers = #{}, name = PortName, options = FT12_options})
      end
  end.

switch_loop(#switch_state{
  name = Name,
  port_ft12 = PortFT12,
  servers = Servers
} = State) ->
  receive
    % Message from FT12
    {data, PortFT12, Frame = #frame{address = LinkAddress}} ->
      % Check if the link address is served by a switch
      case maps:get(LinkAddress, Servers, none) of
        none ->
          ?LOGWARNING("switch received unexpected link address: ~p", [LinkAddress]);
        ServerPID ->
          ServerPID ! {data, self(), Frame}
      end,
      switch_loop(State);

    % Handle send requests from the server
    {send, ServerPID, Frame = #frame{address = LinkAddress}} ->
      % Checking if the link address is served by a switch
      case maps:get(LinkAddress, Servers, none) of
        none ->
          ?LOGWARNING("switch received an unexpected link address for sending data: ~p", [LinkAddress]);
        ServerPID ->
          iec60870_ft12:send(PortFT12, Frame);
        _Other ->
          ?LOGWARNING("switch received unexpected server PID: ~p", [ServerPID])
      end,
      switch_loop(State);

    % Add new server to the switch
    {add_server, ServerPID, LinkAddress } ->
      ServerPID ! {ok, self()},
      switch_loop(State#switch_state{
        % Link addresses are associated with server PIDs
        servers = Servers#{LinkAddress => ServerPID}
      });

    % Port FT12 is down, transport level is unavailable
    {'EXIT', PortFT12, Reason} ->
      ?LOGERROR("switch port ~p exit, ft12 transport error: ~p", [Name, Reason]),
      exit(Reason);

    % Message from the server which has been shut down
    {'EXIT', DeadServer, _Reason} ->
      % Retrieve all servers except the one that has been shut down
      RestServers = maps:filter(fun(_A, PID) -> PID =/= DeadServer end, Servers),
      if
        map_size(RestServers) =:= 0 ->
          ?LOGINFO("switch on port ~p has been shutdown due to no remaining servers", [Name]),
          iec60870_ft12:stop(PortFT12),
          exit(shutdown);
        true ->
          switch_loop(State#switch_state{servers = RestServers})
      end;
    Unexpected ->
      ?LOGWARNING("switch on port ~p received unexpected message: ~p", [Name, Unexpected]),
      switch_loop(State)
  after
    ?SILENT_TIMEOUT ->
      ?LOGWARNING("switch ~p silence timeout, transport reinitialization", [Name]),
      NewState = restart_transport(State),
      ?LOGINFO("switch ~p reinialized after silence timeout", [Name]),
      switch_loop(NewState)
  end.

restart_transport(#switch_state{
  name = Name,
  port_ft12 = PortFT12,
  options = Options
} = State) ->
  ?LOGDEBUG("switch ~p stopping FT12 ~p", [Name, PortFT12]),
  iec60870_ft12:stop(PortFT12),
  wait_stopped(PortFT12),
  ?LOGDEBUG("switch ~p FT12 ~p stopped ", [Name, PortFT12]),
  case catch iec60870_ft12:start_link(Options) of
    {'EXIT', Error} ->
      ?LOGERROR("switch ~p failed to restart transport, error: ~p", [Name, Error]),
      exit({transport_init_fail, Error});
    NewPortFT12 ->
      State#switch_state{port_ft12 = NewPortFT12}
  end.

wait_stopped(PortFT12) ->
  case is_process_alive(PortFT12) of
    true ->
      timer:sleep(10),
      wait_stopped(PortFT12);
    _ ->
      ok
  end.

