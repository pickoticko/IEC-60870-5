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
-define(NOT(X), abs(X - 1)).
-define(CYCLE, 100).

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
  address,
  timeout,
  attempts,
  port,
  fcb
}).

%% +--------------------------------------------------------------+
%% |                             API                              |
%% +--------------------------------------------------------------+

start(Owner, Options) ->
  PID = spawn_link(fun()->init_client(Owner, Options) end),
  receive
    {connected, PID} ->
      PID;
    {'EXIT', PID, Reason} ->
      throw(Reason);
    {'EXIT', Owner, Reason} ->
      exit(PID, Reason)
  end.

stop(Port)->
  exit(Port, shutdown).

%% +--------------------------------------------------------------+
%% |                      Internal functions                      |
%% +--------------------------------------------------------------+

init_client(Owner, #{
  address := Address,
  timeout := Timeout,
  attempts := Attempts
} = Options) ->
  Port = start_port(Options),
  Data = init_connect(#data{
    owner = Owner,
    address = Address,
    timeout = Timeout,
    attempts = Attempts,
    port = Port,
    fcb = 1
  }),
  Owner ! {connected, self()},
  timer:send_after(?CYCLE, {update, self()}),
  loop(Data).

init_connect(#data{
  address = Address
} = Data0)->
  case transaction(?RESET_REMOTE_LINK, Data0) of
    {?RESPONSE(Address, ?ACKNOWLEDGE, _), Data1} ->
      case transaction(?REQUEST_STATUS_LINK, Data1) of
        {?RESPONSE(Address, ?STATUS_LINK_ACCESS_DEMAND, _), Data}->
          Data;
        _ ->
          exit(connect_error)
      end;
    _->
      exit(connect_error)
  end.

loop(#data{
  owner = Owner
} = Data)->
  receive
    {update, Self} when Self =:= self() ->
      timer:send_after(?CYCLE, {update, Self}),
      Data1 = get_data(Data),
      loop(Data1);
    {asdu, Owner, ASDU} ->
      Data1 = send_asdu(ASDU, Data),
      loop(Data1);
    Unexpected ->
      ?LOGWARNING("unexpected message ~p", [Unexpected]),
      loop(Data)
  end.

get_data(#data{
  owner = Owner
} = Data) ->
  Data1 =
    case transaction(?REQUEST_DATA_CLASS_1, Data) of
      {?RESPONSE(_, ?USER_DATA, ASDUClass1), _Data1} ->
        Owner ! {asdu, self(), ASDUClass1},
        _Data1;
      {_, #data{} = _Data1} ->
        _Data1;
      error ->
        init_connect( Data#data{ fcb = 1 })
    end,
  Data2 =
    case transaction(?REQUEST_DATA_CLASS_2, Data1) of
      {?RESPONSE(_, ?USER_DATA, ASDUClass2), _Data2} ->
        Owner ! {asdu, self(), ASDUClass2},
        _Data2;
      {_, #data{} = _Data2} ->
        _Data2;
      error ->
        init_connect( Data#data{ fcb = 1 })
    end,
  Data2.

send_asdu(ASDU, Data) ->
  case transaction(?USER_DATA_CONFIRM, ASDU, Data) of
    {?RESPONSE(_, ?ACKNOWLEDGE, _), Data1} ->
      Data1;
    {Unexpected, _Data} ->
      ?LOGERROR("unexpected send asdu confirmation ~p", [Unexpected]),
      exit(unexpected_data_confirm);
    error ->
      exit(transaction_error)
  end.

transaction(FC, Data) ->
  transaction(FC, undefined, Data).
transaction(FC, UserData, #data{
  attempts = Attempts
} = Data) ->
  transaction(Attempts, FC, UserData, Data).
transaction(Attempts, FC, UserData, #data{
  port = Port,
  address = Address,
  fcb = FCB,
  timeout = Timeout
} = Data) when Attempts > 0 ->
  ReqFCB = handle_fcb(FC, FCB),
  Port ! {request, self(), #frame{
    address = Address,
    control_field = #control_field_request{
      direction = 0,
      fcb = ReqFCB,
      fcv = handle_fcv( FC ),
      function_code = FC
    },
    data = UserData
  }, Timeout},
  receive
    {response, Port, Response} ->
      {Response, Data#data{fcb = ReqFCB}};
    {error, Port} ->
      transaction(Attempts - 1, FC, UserData, Data)
  end;
transaction(_Attempts, _FC, _UserData, _Data)->
  error.

handle_fcv(FC) ->
  case FC of
    ?REQUEST_DATA_CLASS_1 -> 1;
    ?REQUEST_DATA_CLASS_2 -> 1;
    ?USER_DATA_CONFIRM    -> 1;
    _-> 0
  end.

handle_fcb(FC, FCB) ->
  case FC of
    ?RESET_REMOTE_LINK   -> 0;
    ?REQUEST_STATUS_LINK -> 0;
    _-> ?NOT(FCB)
  end.

start_port(#{port := PortName} = Options) ->
  case whereis(list_to_atom(PortName)) of
    Port when is_pid(Port) ->
      Port ! {add_client, self()},
      receive
        {ok, Port} -> Port
      after
        ?START_TIMEOUT-> throw(init_port_timeout)
      end;
    _ ->
      Client = self(),
      Port = spawn_link(fun() -> init_port(Client, Options) end),
      receive
        {ready, Port} -> Port;
        {'EXIT', Port, Reason} -> throw(Reason)
      end
  end.

init_port(Client, Options) ->
  Port = iec60870_ft12:start_link(maps:with([port, port_options, address_size], Options)),
  process_flag(trap_exit, true),
  Client ! {ready, self()},
  port_loop(#port_state{port = Port, clients = #{Client => true}}).

port_loop(#port_state{port = Port, clients = Clients} = State) ->
  receive
    {request, From, #frame{address = Address} = Request, Timeout} ->
      iec60870_ft12:send(Port, Request),
      receive
        {data, Port, #frame{address = Address, control_field = #control_field_response{}} = Response} ->
          From ! {response, self(), Response}
      after
        Timeout->
          iec60870_ft12:clear( Port ),
          From ! {error, self()}
      end,
      port_loop(State);
    {add_client, Client} ->
      link(Client),
      Client ! {ok, self()},
      port_loop(State#port_state{clients = Clients#{Client => true}});
    {'EXIT', Client, _Reason} ->
      case maps:remove(Client, Clients) of
        Clients1 when map_size(Clients1) > 0 ->
          port_loop(State#port_state{clients = Clients1});
        _ ->
          exit(shutdown)
      end;
    Unexpected ->
      ?LOGWARNING("unexpected mesaage received ~p", [Unexpected]),
      port_loop(State)
  end.