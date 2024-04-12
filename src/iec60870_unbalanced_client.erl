-module(iec60870_unbalanced_client).

-include("iec60870.hrl").
-include("ft12.hrl").
-include("unbalanced.hrl").

-export([
  start/2,
  stop/1
]).

%% +--------------------------------------------------------------+
%% |                           Macros                             |
%% +--------------------------------------------------------------+

-define(START_TIMEOUT, 1000).
-define(CYCLE, 100).

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
  port,
  clients
}).

-record(data, {
  owner,
  port
}).

%% +--------------------------------------------------------------+
%% |                             API                              |
%% +--------------------------------------------------------------+

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

stop(Port)->
  exit(Port, shutdown).

%% +--------------------------------------------------------------+
%% |                      Internal functions                      |
%% +--------------------------------------------------------------+

init_client(Owner, Options) ->
  Port = start_port(Options),
  Owner ! {connected, self()},
  timer:send_after(?CYCLE, {update, self()}),
  loop(#data{
    owner = Owner,
    port = Port
  }).

loop(#data{
  owner = Owner,
  port = Port
} = Data) ->
  receive
    {update, Self} when Self =:= self() ->
      timer:send_after(?CYCLE, {update, Self}),
      get_data(Data),
      loop(Data);
    {asdu, Owner, ASDU} ->
      case send_asdu(ASDU, Port) of
        ok ->
          success;
        {error, Error} ->
          %% Failed send errors are handled by client state machine
          Owner ! {send_error, self(), Error}
      end,
      loop(Data);
    Unexpected ->
      ?LOGWARNING("client received unexpected message: ~p", [Unexpected]),
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
    ok-> ok;
    {error, Error} -> {error, Error}
  end.

transaction(FC, Data, Port, OnResponse) ->
  Port ! {request, self(), FC, Data, OnResponse},
  receive
    {ok, Port} -> ok;
    {error, Port, Error} -> {error, Error};
    {'EXIT', Port, Reason} -> {error, {port_error, Reason}}
  end.

%% +--------------------------------------------------------------+
%% |                         Shared port                          |
%% +--------------------------------------------------------------+

start_port(Options) ->
  Client = self(),
  PID = spawn(fun() -> init_port(Client, Options) end),
  receive
    {ready, PID, Port} -> Port;
    {'EXIT', PID, Reason} -> exit(Reason)
  end.

init_port(Client, #{port := PortName} = Options) ->
  case iec60870_lib:try_register(list_to_atom(PortName), self()) of
    % Succeeded to register port
    % Initializing port
    ok ->
      process_flag(trap_exit, true),
      link(Client),
      Port = iec60870_ft12:start_link(maps:with([port, port_options, address_size], Options)),
      case start_client(Port, Client, Options) of
        {ok, State} ->
          Client ! {ready, self(), Port},
          port_loop(#port_state{port = Port, clients = #{Client => State}});
        {error, Error} ->
          exit(Error)
      end;
    % Port registration failed, it probably already exists elsewhere.
    % Check for existing port.
    {error, failed} ->
      case whereis(list_to_atom(PortName)) of
        Port when is_pid(Port) ->
          Port ! {add_client, Client, Options},
          receive
            {success, Port} ->
              Client ! {ready, self(), Port},
              Port;
            {error, Port, Error} -> exit(Error);
            {'EXIT', Port, Reason} -> exit(Reason)
          end;
        % No registered ports found
        _Error ->
          ?LOGERROR("failed to get shared port"),
          exit(shutdown)
      end
  end.

port_loop(#port_state{port = Port, clients = Clients} = SharedState) ->
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
          end
      end;

    {add_client, Client, Options} ->
      case start_client(Port, Client, Options) of
        {ok, NewClientState} ->
          link(Client),
          Client ! {success, self()},
          port_loop(SharedState#port_state{
            clients = Clients#{
              Client => NewClientState
            }
          });
        {error, Error} ->
          exit(Error)
      end;

    {'EXIT', Client, Reason} ->
      port_loop(SharedState#port_state{clients = stop_client(Client, Clients, Reason)});
    {'DOWN', _, process, Client, Reason}->
      port_loop(SharedState#port_state{clients = stop_client(Client, Clients, Reason)});

    Unexpected ->
      ?LOGWARNING("client received unexpected message: ~p", [Unexpected]),
      port_loop(SharedState)
  end.

start_client(Port, Client, #{
  address := Address,
  timeout := Timeout,
  attempts := Attempts
}) ->
  SendReceive = fun(Request) -> iec60870_101:send_receive(Port, Request, Timeout) end,
  case iec60870_101:connect(Address, _Direction = 0, SendReceive, Attempts) of
    {ok, State} ->
      erlang:monitor(process, Client),
      {ok, State};
    Error ->
      Error
  end.

stop_client(Client, Clients, Reason)->
  case maps:remove(Client, Clients) of
    Clients1 when map_size(Clients1) > 0 ->
      Clients1;
    _ ->
      ?LOGERROR("client is shut down due to a reason: ~p", [Reason]),
      exit(shutdown)
  end.