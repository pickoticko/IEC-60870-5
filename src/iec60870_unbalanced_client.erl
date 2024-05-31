%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_unbalanced_client).

-include("iec60870.hrl").
-include("ft12.hrl").
-include("unbalanced.hrl").

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

-define(START_TIMEOUT, 1000).
-define(DEFAULT_CYCLE, 10).

-define(NOT(X), abs(X - 1)).

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
  exit(Port, shutdown).

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init_client(Owner, Options) ->
  Port = start_port(Options),
  connect(Port, Options),
  Owner ! {connected, self()},
  Cycle = maps:get(cycle, Options, ?DEFAULT_CYCLE),
  timer:send_after(Cycle, {update, self()}),
  loop(#data{
    name = maps:get(port, Options),
    cycle = Cycle,
    owner = Owner,
    port = Port
  }).

connect(Port, Options) ->
  erlang:monitor(process, Port),
  Port ! {add_client, self(), Options},
  receive
    {ok, Port} -> ok;
    {error, Port, ConnectError} ->
      exit(ConnectError);
    {'DOWN', _, process, Port, Reason} ->
      exit(Reason)
  end.

loop(#data{
  name = Name,
  owner = Owner,
  port = Port,
  cycle = Cycle
} = Data) ->
  receive
    {update, Self} when Self =:= self() ->
      timer:send_after(Cycle, {update, Self}),
      get_data(Data),
      loop(Data);
    {asdu, Owner, ASDU} ->
      case send_asdu(ASDU, Port) of
        ok ->
          success;
        {error, Error} ->
          % Failed send errors are handled by client state machine
          Owner ! {send_error, self(), Error}
      end,
      loop(Data);
    {'DOWN', _, process, Port, Reason} ->
      ?LOGWARNING("~p client down because of the port error: ~p", [Name, Reason]),
      exit({down_port, Reason});
    Unexpected ->
      ?LOGWARNING("~p client received unexpected message: ~p", [Name, Unexpected]),
      loop(Data)
  end.

get_data(#data{
  owner = Owner,
  port = Port
}) ->
  Self = self(),
  OnResponse =
    fun(Response) ->
      case Response of
        #frame{control_field = #control_field_response{function_code = TestFC, dfc = 1}} ->
          ?LOGINFO("DEBUG: Client received DFC enabled (OVERFLOW) with FC: ~p", [TestFC]);
        _ ->
          ignore
      end,
      case Response of
        #frame{control_field = #control_field_response{function_code = ?USER_DATA}, data = ASDUClass1} ->
          Owner ! {asdu, Self, ASDUClass1},
          ok;
        #frame{control_field = #control_field_response{function_code = ?NACK_DATA_NOT_AVAILABLE}} ->
          ok;
        _ ->
          error
      end
    end,
  %% +-----------[ Class 1 data request ]-----------+
  case transaction(?REQUEST_DATA_CLASS_1, _Data1 = undefined, Port, OnResponse) of
    ok -> ok;
    {error, ErrorClass1} -> exit(ErrorClass1)
  end,
  %% +-----------[ Class 2 data request ]-----------+
  case transaction(?REQUEST_DATA_CLASS_2, _Data2 = undefined, Port, OnResponse) of
    ok -> ok;
    {error, ErrorClass2} -> exit(ErrorClass2)
  end.

send_asdu(ASDU, Port) ->
  OnResponse =
    fun(Response) ->
      case Response of
        #frame{control_field = #control_field_response{function_code = ?ACKNOWLEDGE}} ->
          ok;
        _ ->
          error
      end
    end,
  case transaction(?USER_DATA_CONFIRM, ASDU, Port, OnResponse) of
    ok -> ok;
    {error, Error} -> {error, Error}
  end.

transaction(FC, Data, Port, OnResponse) ->
  Port ! {request, self(), FC, Data, OnResponse},
  receive
    {ok, Port} -> ok;
    {error, Port, Error} -> {error, Error};
    {'EXIT', Port, Reason} -> {error, {port_error, Reason}}
  end.

%%% +--------------------------------------------------------------+
%%% |                         Shared port                          |
%%% +--------------------------------------------------------------+

start_port(Options) ->
  Client = self(),
  PID = spawn(fun() -> init_port(Client, Options) end),
  receive
    {ready, PID, Port} ->
      Port;
    {error, PID, InitError} ->
      exit(InitError)
  end.

init_port(Client, #{port := PortName} = Options) ->
  RegisterName = list_to_atom(PortName),
  case catch register(RegisterName, self()) of
    {'EXIT', _} ->
      case whereis(RegisterName) of
        Port when is_pid(Port) ->
          Client ! {ready, self(), Port};
        _ ->
          init_client(Client, Options)
      end;
    true ->
      case catch iec60870_ft12:start_link(maps:with([port, port_options, address_size], Options)) of
        {'EXIT', _} ->
          Client ! {error, self(), serial_port_init_fail};
        PortFT12 ->
          Client ! {ready, self(), self()},
          port_loop(#port_state{port_ft12 = PortFT12, clients = #{}, name = PortName})
      end
  end.

port_loop(#port_state{port_ft12 = PortFT12, clients = Clients, name = Name} = SharedState) ->
  receive
    {request, From, FC, Data, OnResponse} ->
      case Clients of
        #{From := ClientState} ->
          case iec60870_101:transaction(FC, Data, OnResponse, ClientState) of
            {ok, NewClientState} ->
              From ! {ok, self()},
              port_loop(SharedState#port_state{
                clients = Clients#{
                  From => NewClientState
                }
              });
            {error, Error} ->
              From ! {error, self(), Error},
              port_loop(SharedState)
          end;
        _Unexpected ->
          ?LOGWARNING("switch ignored a request from an undefined process: ~p", [From]),
          port_loop(SharedState)
      end;

    {add_client, Client, Options} ->
      case start_client(PortFT12, Options) of
        {ok, NewClientState} ->
          erlang:monitor(process, Client),
          Client ! {ok, self()},
          port_loop(SharedState#port_state{
            clients = Clients#{
              Client => NewClientState
            }
          });
        {error, Error} ->
          Client ! {error, self(), Error},
          port_loop(SharedState)
      end;

    % Client is down due to some reason
    {'DOWN', _, process, Client, _Reason} ->
      RestClients = maps:remove(Client, Clients),
      if
        % No clients left, we should stop the shared port
        map_size(RestClients) =:= 0 ->
          ?LOGINFO("shared port ~p has been shutdown due to no clients remaining", [Name]),
          exit(normal);
        true ->
          port_loop(SharedState#port_state{clients = RestClients})
      end;

    Unexpected ->
      ?LOGWARNING("shared port received unexpected message: ~p", [Unexpected]),
      port_loop(SharedState)
  end.

start_client(PortFT12, #{
  address := Address,
  timeout := Timeout,
  attempts := Attempts
}) ->
  SendReceive = fun(Request) -> iec60870_101:send_receive(PortFT12, Request, Timeout) end,
  case iec60870_101:connect(Address, _Direction = 0, SendReceive, Attempts) of
    {ok, State} ->
      {ok, State};
    Error ->
      Error
  end.
