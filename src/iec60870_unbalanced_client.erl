%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_unbalanced_client).

-include("iec60870.hrl").
-include("ft12.hrl").
-include("function_codes.hrl").

%%% +--------------------------------------------------------------+
%%% |                             API                              |
%%% +--------------------------------------------------------------+

-export([
  start/2,
  stop/1
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-define(RESPONSE(Address, FC, UserData), #frame{
  address = Address,
  control_field = #control_field_response{
    direction = 0,
    acd = 0,
    dfc = 0,
    function_code = FC
  },
  data = UserData
}).

-record(port_state, {
  name,
  port_ft12,
  clients
}).

-record(data, {
  state,
  name,
  owner,
  port,
  cycle
}).

%%% +--------------------------------------------------------------+
%%% |                       API implementation                     |
%%% +--------------------------------------------------------------+

start(Owner, Options) ->
  PID = spawn_link(fun() -> init_client(Owner, Options) end),
  receive
    {connected, PID} ->
      PID;
    {'EXIT', PID, Reason} ->
      ?LOGERROR("client is down due to a reason: ~p", [Reason]),
      throw(Reason);
    {'EXIT', Owner, Reason} ->
      ?LOGERROR("client is down due to owner process shutdown, reason: ~p", [Reason]),
      exit(PID, Reason)
  end.

stop(Port) ->
  catch exit(Port, shutdown).

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init_client(Owner, #{cycle := Cycle, transport := #{name := PortName}} = Options) ->
  Port = start_port(Options),
  State = connect(Port, Options),
  Owner ! {connected, self()},
  self() ! {update, self()},
  loop(#data{
    state = State,
    name = PortName,
    cycle = Cycle,
    owner = Owner,
    port = Port
  }).

connect(Port, Options) ->
  Port ! {add_client, self(), Options},
  receive
    {ok, Port, ClientState} ->
      ClientState;
    {error, Port, ConnectError} ->
      exit(ConnectError)
  end.

loop(#data{
  name = Name,
  owner = Owner,
  cycle = Cycle
} = Data) ->
  receive
    {update, Self} when Self =:= self() ->
      ?LOGDEBUG("client ~p: received update event from itself", [Name]),
      timer:send_after(Cycle, {update, Self}),
      NewData = get_data(Data),
      loop(NewData);
    {access_demand, Self} when Self =:= self() ->
      ?LOGDEBUG("client ~p: received access_demand event from itself", [Name]),
      NewData = get_data(Data),
      loop(NewData);
    {asdu, Owner, Reference, ASDU} ->
      Owner!{confirm, Reference},
      NewData = send_asdu(ASDU, Data),
      loop(NewData);
    Unexpected ->
      ?LOGWARNING("~p client received unexpected message: ~p", [Name, Unexpected]),
      loop(Data)
  end.

get_data(Data) ->
  drop_access_demand(),
  NewData = send_data_class_request(?REQUEST_DATA_CLASS_1, Data),
  send_data_class_request(?REQUEST_DATA_CLASS_2, NewData).

drop_access_demand() ->
  receive
    {access_demand, _AnyPID} ->
      drop_access_demand()
  after
    0 -> ok
  end.

send_data_class_request(DataClass, #data{
  state = State,
  port = Port,
  owner = Owner
} = Data) ->
  DataClassRequest = fun() -> iec60870_101:data_class(DataClass, State) end,
  case send_request(Port, DataClassRequest) of
    error ->
      ?LOGERROR("~p failed to request data class 1", [Port]),
      exit({error, {request_data_class, DataClass}});
    {NewState, ACD, ASDU} ->
      send_asdu_to_owner(Owner, ASDU),
      check_access_demand(ACD),
      Data#data{state = NewState}
  end.

send_request(Port, Function) ->
  Port ! {request, self(), Function},
  receive
    {Port, Result} -> Result;
    {'DOWN', _, process, Port, Reason} -> exit( Reason )
  end.

send_asdu(ASDU, #data{
  state = State,
  port = Port,
  owner = Owner,
  name = Name
} = Data) ->
  Request = fun() -> iec60870_101:user_data_confirm(ASDU, State) end,
  case send_request(Port, Request) of
    error ->
      %% TODO: Diagnostics. send_asdu, {error, timeout}
      ?LOGERROR("~p unbalanced failed to send ASDU", [Name]),
      Owner ! {send_error, self(), timeout},
      Data;
    NewState ->
      %% TODO: Diagnostics. send_asdu, ok
      ?LOGDEBUG("~p unbalanced send ASDU is OK", [Name]),
      Data#data{state = NewState}
  end.

%%% +--------------------------------------------------------------+
%%% |                         Shared port                          |
%%% +--------------------------------------------------------------+

start_port(Options) ->
  Client = self(),
  PID = spawn_link(fun() -> init_port(Client, Options) end),
  receive
    {ready, PID, PID} ->
      PID;
    {ready, PID, Port} ->
      link(Port),
      Port
  end.

init_port(Client, #{transport := #{name := Name}} = Options) ->
  RegisterName = list_to_atom(Name),
  case catch register(RegisterName, self()) of
    {'EXIT', _} ->
      case whereis(RegisterName) of
        Port when is_pid(Port) ->
          Client ! {ready, self(), Port};
        _ ->
          init_client(Client, Options)
      end;
    true ->
      case catch iec60870_ft12:start_link(maps:with([transport, address_size], Options)) of
        {'EXIT', Error} ->
          ?LOGERROR("shared port ~p failed to start transport, error: ~p", [Name, Error]),
          exit({transport_init_fail, Error});
        PortFT12 ->
          process_flag(trap_exit, true),
          ?LOGDEBUG("shared port ~p is started", [Name]),
          Client ! {ready, self(), self()},
          port_loop(#port_state{port_ft12 = PortFT12, clients = #{}, name = Name})
      end
  end.

port_loop(#port_state{port_ft12 = PortFT12, clients = Clients, name = Name} = SharedState) ->
  receive
    {request, From, Function} ->
      case Clients of
        #{From := true} ->
          From ! {self(), Function()};
        _Unexpected ->
          ?LOGWARNING("switch ignored a request from an undefined process: ~p", [From])
      end,
      port_loop(SharedState);

    {add_client, Client, Options} ->
      case iec60870_101:connect(Options#{portFT12 => PortFT12, direction => 0}) of
        error ->
          ?LOGERROR("shared port ~p failed to add client: ~p", [Name, Client]),
          Client ! {error, self(), timeout},
          State1 = check_stop(SharedState),
          port_loop(State1);
        ClientState ->
          ?LOGDEBUG("shared port ~p added a client ~p", [Name, Client]),
          Client ! {ok, self(), ClientState},
          port_loop(SharedState#port_state{clients = Clients#{Client => true}})
      end;

    % Port FT12 is down, transport level is unavailable
    {'EXIT', PortFT12, Reason} ->
      ?LOGERROR("shared port ~p exit, ft12 transport error: ~p", [Name, Reason]),
      exit({transport_error, Reason});

    % Client is down due to some reason
    {'EXIT', Client, Reason} ->
      ?LOGDEBUG("shared port ~p client ~p exit, reason ~p", [Name, Client, Reason]),
      State1 = check_stop(SharedState#port_state{clients = maps:remove(Client, Clients)}),
      port_loop(State1);

    Unexpected ->
      ?LOGWARNING("shared port received unexpected message: ~p", [Unexpected]),
      port_loop(SharedState)
  end.

check_stop(#port_state{
  clients = Clients,
  port_ft12 = PortFT12,
  name = Name
} = State) ->
  if
  % No clients left, we should stop the shared port
    map_size(Clients) =:= 0 ->
      ?LOGINFO("shared port ~p has been shutdown due to no clients remaining", [Name]),
      iec60870_ft12:stop(PortFT12),
      exit(shutdown);
    true ->
      State
  end.

%% Send ASDU to the owner if it exists
send_asdu_to_owner(_Owner, _ASDU = undefined) ->
  ok;
send_asdu_to_owner(Owner, ASDU) ->
  Owner ! {asdu, self(), ASDU}.

%% The server set the signal that it has data to send
check_access_demand(_ACD = 1) ->
  self() ! {access_demand, self()};
check_access_demand(_ACD) ->
  ok.