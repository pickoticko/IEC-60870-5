-module(iec60870_balanced).

-include("iec60870.hrl").
-include("ft12.hrl").
-include("balanced.hrl").

-export([
  start/2,
  stop/1
]).

%% +--------------------------------------------------------------+
%% |                           Macros                             |
%% +--------------------------------------------------------------+

-define(ACKNOWLEDGE_FRAME(Address, Direction),#frame{
  address = Address,
  control_field = #control_field_response{
    direction = Direction,
    acd = 0,
    dfc = 0,
    function_code = ?ACKNOWLEDGE
  }
}).

-define(RESPONSE(Address, Direction, FC), #frame{
  address = Address,
  control_field = #control_field_response{
    direction = Direction,
    acd = 0,
    dfc = 0,
    function_code = FC
  }
}).

-define(NOT(X), abs(X - 1)).
-define(TIMESTAMP, erlang:system_time(millisecond)).
-define(DURATION(T), (?TIMESTAMP - T)).

-record(data, {
  owner,
  address,
  timeout,
  attempts,
  direction,
  port,
  out_fcb,
  in_fcb,
  sent_frame,
  connection,
  linked
}).

%% +--------------------------------------------------------------+
%% |                             API                              |
%% +--------------------------------------------------------------+

start(Direction, Options) ->
  Owner = self(),
  PID = spawn_link(fun() -> init(Owner, Direction, Options) end),
  receive
    {ready, PID} -> PID;
    {'EXIT', PID, Reason} -> throw(Reason)
  end.

stop(PID) ->
  PID ! {stop, self()}.

%% +--------------------------------------------------------------+
%% |                      Internal functions                      |
%% +--------------------------------------------------------------+

init(Owner, Direction, #{
  address := Address,
  timeout := Timeout,
  attempts := Attempts
} = Options) ->
  Port = iec60870_ft12:start_link(maps:with([port, port_options, address_size], Options)),
  Owner ! {ready, self()},
  Data = init_connect(#data{
    owner = Owner,
    address = Address,
    direction = Direction,
    timeout = Timeout,
    attempts = Attempts,
    port = Port,
    connection = undefined,
    linked = false,
    out_fcb = 1
  }),
  Owner ! {connected, self()},
  Connection =
    receive
      {connection, Owner, _Connection} -> _Connection
    end,
  send_delayed_asdu(Connection),
  loop(Data#data{connection = Connection}).

init_connect(Data0) ->
  case transaction(?RESET_REMOTE_LINK, Data0) of
    #data{} = Data1 ->
      case transaction(?REQUEST_STATUS_LINK, Data1) of
        #data{} = Data ->
          Data;
        error ->
          exit(connect_error)
      end;
    error ->
      exit(connect_error)
  end.

send_delayed_asdu(Connection)->
  receive
    {asdu, Self, ASDU} when Self =:= self() ->
      Connection ! {asdu, Self, ASDU},
      send_delayed_asdu(Connection)
  after
    0 -> ok
  end.

loop(#data{
  owner = Owner,
  port = Port,
  address = Address,
  in_fcb = FCB,
  sent_frame = SentFrame,
  connection = Connection
} = Data) ->
  receive
    {data, Port, #frame{address = ReqAddress}} when ReqAddress =/= Address ->
      loop(Data);
    {data, Port, Unexpected = #frame{control_field = #control_field_response{}}} ->
      ?LOGWARNING("unexpected response frame received ~p", [Unexpected]),
      loop(Data);
    {data, Port, #frame{control_field = CF, data = UserData}} ->
      case check_fcb(CF, FCB) of
        {ok, NextFCB} ->
          Data1 = handle_request(CF#control_field_request.function_code, UserData, Data),
          loop(Data1#data{in_fcb = NextFCB});
        error ->
          ?LOGWARNING("check fcb error, cf ~p, FCB ~p", [CF, FCB]),
          case SentFrame of
            #frame{} -> iec60870_ft12:send(Port, SentFrame);
            _ -> ignore
          end,
          loop(Data)
      end;
    {asdu, Connection, ASDU} ->
      case transaction(?USER_DATA_CONFIRM, ASDU, Data) of
        #data{} = Data1 ->
          loop(Data1);
        error ->
          exit(transaction_error)
      end;
    {stop, Owner} ->
      iec60870_ft12:stop(port);
    Unexpected ->
      ?LOGWARNING("unexpected message received: ~p", [Unexpected]),
      loop(Data)
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
  out_fcb = FCB,
  direction = Direction,
  timeout = Timeout
} = Data) when Attempts > 0 ->
  ReqFCB = handle_fcb(FC, FCB),
  iec60870_ft12:send(Port, #frame{
    address = Address,
    control_field = #control_field_request{
      direction = Direction,
      fcb = ReqFCB,
      fcv = handle_fcv(FC),
      function_code = FC
    },
    data = UserData
  }),
  Response = ?RESPONSE(Address, ?NOT(Direction), response_fc(FC)),
  case await_response(Timeout, Response, Data#data{out_fcb = ReqFCB}) of
    #data{} = Data1 ->
      Data1;
    {error, Data1} ->
      transaction(Attempts - 1, FC, UserData, Data1)
  end;
transaction(_Attempts, _FC, _UserData, _Data)->
  error.

await_response(_Timeout, ?RESPONSE(_, _, undefined), Data)->
  Data;
await_response(Timeout, Response, #data{
  port = Port,
  address = Address
} = Data) when Timeout > 0 ->
  CurrentTime = ?TIMESTAMP,
  receive
    {data, Port, Response} ->
      Data;
    {data, Port, #frame{address = ReqAddress} = Unexpected} when ReqAddress =/= Address ->
      ?LOGWARNING("unexpected address frame received ~p", [Unexpected]),
      await_response(Timeout - ?DURATION(CurrentTime), Response, Data);
    {data, Port, #frame{control_field = #control_field_response{}} = Unexpected} ->
      ?LOGWARNING("unexpected response frame received ~p, wait for ~p", [Unexpected, Response]),
      await_response(Timeout - ?DURATION(CurrentTime), Response, Data);
    {data, Port, #frame{control_field = CF, data = UserData}} ->
      Data1 = handle_request(CF#control_field_request.function_code, UserData, Data),
      await_response(Timeout - ?DURATION(CurrentTime), Response, Data1)
  after
    Timeout -> {error,Data}
  end;
await_response(_Timeout, _FC, Data)->
  {error, Data}.

handle_fcv(FC)->
  case FC of
    ?LINK_TEST         -> 1;
    ?USER_DATA_CONFIRM -> 1;
    _Other -> 0
  end.

handle_fcb(FC, FCB) ->
  case FC of
    ?RESET_REMOTE_LINK   -> 0;
    ?REQUEST_STATUS_LINK -> 0;
    _Other -> ?NOT(FCB)
  end.

response_fc(FC) ->
  case FC of
    ?USER_DATA_NO_REPLY  -> undefined;
    ?ACCESS_DEMAND       -> ?STATUS_LINK_ACCESS_DEMAND;
    ?REQUEST_STATUS_LINK -> ?STATUS_LINK_ACCESS_DEMAND;
    _Other -> ?ACKNOWLEDGE
  end.

check_fcb(#control_field_request{fcv = 0, fcb = _ReqFCB}, _FCB) ->
  {ok, 0}; %% TODO. Is it correct to treat fcv = 0 as a reset?
check_fcb(#control_field_request{fcv = 1, fcb = FCB }, FCB) ->
  error;
check_fcb(#control_field_request{fcv = 1, fcb = RecFCB}, _FCB ) ->
  {ok, RecFCB}.

handle_request(?RESET_REMOTE_LINK, _UserData, #data{
  port = Port,
  address = Address,
  direction = Direction
} = Data) ->
  Data#data{
    sent_frame = send_response(Port, ?ACKNOWLEDGE_FRAME(Address, Direction))
  };

handle_request(?RESET_USER_PROCESS, _UserData, #data{
  port = Port,
  address = Address,
  direction = Direction
} = Data) ->
  %% TODO: Do we need to take any action? Perhaps restart the connection?"
  Data#data{
    sent_frame = send_response(Port, ?ACKNOWLEDGE_FRAME(Address, Direction))
  };

handle_request(?USER_DATA_CONFIRM, ASDU, #data{
  connection = Connection,
  port = Port,
  address = Address,
  direction = Direction
} = Data) ->
  if
    is_pid(Connection) ->
      Connection ! {asdu, self(), ASDU};
    true ->
      self() ! {asdu, self(), ASDU}
  end,
  Data#data{
    sent_frame = send_response(Port, ?ACKNOWLEDGE_FRAME(Address, Direction))
  };

handle_request(?USER_DATA_NO_REPLY, ASDU, #data{
  connection = Connection
} = Data) ->
  if
    is_pid(Connection) ->
      Connection ! {asdu, self(), ASDU};
    true ->
      self() ! {asdu, self(), ASDU}
  end,
  Data;

handle_request(?ACCESS_DEMAND, _UserData, #data{
  port = Port,
  address = Address,
  direction = Direction
} = Data)->
  Data#data{
    sent_frame = send_response(Port, #frame{
      address = Address,
      control_field = #control_field_response{
        direction = Direction,
        acd = 0,
        dfc = 0,
        function_code = ?STATUS_LINK_ACCESS_DEMAND
      }
    })
  };

handle_request(?REQUEST_STATUS_LINK, _UserData, #data{
  port = Port,
  address = Address,
  direction = Direction,
  linked = Linked
} = Data)->
  if
    Linked =:= true, Direction =:= 1 ->
      %% If it's a server, the link request is accepted as a command to reset the connection
      exit(reset_connection);
    true ->
      Data#data{
        linked = true,
        sent_frame = send_response(Port, #frame{
          address = Address,
          control_field = #control_field_response{
            direction = Direction,
            acd = 0,
            dfc = 0,
            function_code = ?STATUS_LINK_ACCESS_DEMAND
          }
        })
      }
  end;

handle_request(InvalidFC, _UserData, Data) ->
  ?LOGERROR("invalid request function code received ~p", [InvalidFC]),
  Data.

send_response(Port, Frame) ->
  iec60870_ft12:send(Port, Frame),
  Frame.