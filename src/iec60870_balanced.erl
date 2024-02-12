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

-define(TIMESTAMP, erlang:system_time(millisecond)).
-define(DURATION(T), (?TIMESTAMP - T)).

-record(data, {
  owner,
  address,
  direction,
  port,
  state,
  connection
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
  Data = #data{
    owner = Owner,
    address = Address,
    direction = Direction,
    port = Port
  },
  SendReceive = fun(Request) -> send_receive(Data, Request, Timeout) end,
  case iec60870_101:connect(Address, Direction, SendReceive, Attempts) of
    {ok, State} ->
      Owner ! {connected, self()},
      Connection =
        receive
          {connection, Owner, _Connection} -> _Connection
        end,
      send_delayed_asdu(Connection),
      loop(#data{
        owner = Owner,
        address = Address,
        direction = Direction,
        state = State,
        port = Port,
        connection = Connection
      });
    {error, Error} ->
      exit(Error)
  end.

send_delayed_asdu(Connection) ->
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
  connection = Connection,
  state = State
} = Data) ->
  receive
    {data, Port, #frame{address = ReqAddress}} when ReqAddress =/= Address ->
      loop(Data);
    {data, Port, #frame{control_field = #control_field_request{} =CF, data = UserData}} ->
      case check_fcb( CF ) of
        ok ->
          Data1 = handle_request(CF#control_field_request.function_code, UserData, Data),
          loop( Data1 );
        error ->
          ?LOGWARNING("check fcb error, cf ~p", [CF]),
          % On error we have to repeat the last sent frame
          case get( sent_frame ) of
            RepeatFrame = #frame{} ->
              % On error we should repeat the last sent frame
              iec60870_ft12:send(Port, RepeatFrame);
            _->
              ignore
          end,
          loop(Data)
      end;
    {asdu, Connection, ASDU} ->
      OnResponse =
        fun( Response )->
          case Response of
            #frame{ control_field = #control_field_response{ function_code = ?ACKNOWLEDGE }}->
              ok;
            _->
              error
          end
        end,
      case iec60870_101:transaction(?USER_DATA_CONFIRM, ASDU, OnResponse, State) of
        {ok, State1} ->
          loop(Data#data{state = State1});
        {error, Error} ->
          Owner ! {send_error, self(), Error},
          loop(Data)
      end;
    {stop, Owner} ->
      iec60870_ft12:stop(Port);
    Unexpected ->
      ?LOGWARNING("unexpected message ~p",[ Unexpected ]),
      loop( Data )
  end.

send_receive( #data{ port = Port } = Data, Request, Timeout )->
  iec60870_ft12:send(Port, Request),
  await_response( Timeout, Data ).

await_response(Timeout, #data{
  port = Port,
  address = Address
} = Data) when Timeout > 0 ->
  CurrentTime = ?TIMESTAMP,
  receive
    {data, Port, #frame{address = ReqAddress} = Unexpected} when ReqAddress =/= Address ->
      ?LOGWARNING("unexpected address frame received ~p", [Unexpected]),
      await_response(Timeout - ?DURATION(CurrentTime), Data);
    {data, Port, #frame{control_field = #control_field_response{}} = Response} ->
      {ok, Response};

    {data, Port, #frame{control_field = #control_field_request{} =CF, data = UserData}} ->
      handle_request(CF#control_field_request.function_code, UserData, Data),
      await_response(Timeout - ?DURATION(CurrentTime), Data)
  after
    Timeout -> {error,Data}
  end;
await_response(_Timeout, _Data)->
  {error, timeout}.

check_fcb( #control_field_request{fcv = 0, fcb = _ReqFCB} )->
  put(fcb, 0), %% TODO. Is it correct to treat fcv = 0 as a reset?
  ok;
check_fcb( #control_field_request{fcv = 1, fcb = FCB } )->
  case get( fcb ) of
    FCB ->
      % FCB must not be the same
      error;
    NextFCB->
      put( fcb, NextFCB ),
      ok
  end.

handle_request(?RESET_REMOTE_LINK, _UserData, #data{
  port = Port,
  address = Address,
  direction = Direction
}) ->
  send_response(Port, ?ACKNOWLEDGE_FRAME(Address, Direction));

handle_request(?RESET_USER_PROCESS, _UserData, #data{
  port = Port,
  address = Address,
  direction = Direction
}) ->
  %% TODO: Do we need to take any action? Perhaps restart the connection?"
  send_response(Port, ?ACKNOWLEDGE_FRAME(Address, Direction));

handle_request(?USER_DATA_CONFIRM, ASDU, #data{
  connection = Connection,
  port = Port,
  address = Address,
  direction = Direction
}) ->
  if
    is_pid(Connection) ->
      Connection ! {asdu, self(), ASDU};
    true ->
      self() ! {asdu, self(), ASDU}
  end,
  send_response(Port, ?ACKNOWLEDGE_FRAME(Address, Direction));

handle_request(?USER_DATA_NO_REPLY, ASDU, #data{
  connection = Connection
}) ->
  if
    is_pid(Connection) ->
      Connection ! {asdu, self(), ASDU};
    true ->
      self() ! {asdu, self(), ASDU}
  end,
  ok;

handle_request(?ACCESS_DEMAND, _UserData, #data{
  port = Port,
  address = Address,
  direction = Direction
})->
  send_response(Port, #frame{
    address = Address,
    control_field = #control_field_response{
      direction = Direction,
      acd = 0,
      dfc = 0,
      function_code = ?STATUS_LINK_ACCESS_DEMAND
    }
  });

handle_request(?REQUEST_STATUS_LINK, _UserData, #data{
  port = Port,
  address = Address,
  direction = Direction
}) ->
  send_response(Port, #frame{
    address = Address,
    control_field = #control_field_response{
      direction = Direction,
      acd = 0,
      dfc = 0,
      function_code = ?STATUS_LINK_ACCESS_DEMAND
    }
  });

handle_request(InvalidFC, _UserData, _Data) ->
  ?LOGERROR("invalid request function code received ~p", [InvalidFC]),
  ok.

send_response(Port, Frame) ->
  iec60870_ft12:send(Port, Frame),
  put(sent_frame, Frame),
  ok.