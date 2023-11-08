
-module(iec60870_balanced).

-include("iec60870.hrl").
-include("ft12.hrl").
-include("balanced.hrl").

%% API
-export([
  start/2,
  stop/1
]).

-define(ACKNOWLEDGE_FRAME(Address, Dir),#frame{
  address = Address,
  control_field = #control_field_response{
    direction = Dir,
    acd = 0,
    dfc = 0,
    function_code = ?ACKNOWLEDGE
  }
}).

-define(RESPONSE(Address, Dir, FC), #frame{
  address = Address,
  control_field = #control_field_response{
    direction = Dir,
    acd = 0,
    dfc = 0,
    function_code = FC
  }
}).

-define(NOT(X), abs(X-1)).
-define(TS, erlang:system_time(millisecond)).
-define(DUR(T),(?TS - T) ).

-record(data, {
  owner,
  address,
  timeout,
  attempts,
  dir,
  port,
  out_fcb,
  in_fcb,
  sent_frame,
  connection
}).

start(Dir, Options ) ->
  Owner = self(),
  PID = spawn_link( fun() -> init(Owner, Dir, Options) end),
  receive
    {ready, PID} -> PID;
    {'EXIT', PID, Reason} -> throw(Reason)
  end.

stop( PID )->
  PID ! { stop, self() }.

init(Owner, Dir, #{
  address := Address,
  timeout := Timeout,
  attempts := Attempts
} = Options) ->

  Port = iec60870_ft12:start_link( maps:with([ port, port_options, address_size ], Options) ),

  Owner ! { ready, self()},

  Data = init_connect(#data{
    owner = Owner,
    address = Address,
    dir = Dir,
    timeout = Timeout,
    attempts = Attempts,
    port = Port,
    connection = undefined,
    out_fcb = 1
  }),

  Owner ! { connected, self() },
  Connection =
    receive { connection, Owner, _Connection } -> _Connection end,

  loop( Data#data{ connection = Connection } ).


init_connect( Data0 )->

  case transaction(?RESET_REMOTE_LINK, Data0) of
    #data{} = Data1 ->
      case transaction( ?REQUEST_STATUS_LINK, Data1) of
        #data{} = Data->
          Data;
        error->
          exit( connect_error )
      end;
    error->
      exit( connect_error )
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
    {data, Port, #frame{ address = ReqAddress }} when ReqAddress =/= Address ->
      loop( Data );
    {data, Port, Unexpected = #frame{ control_field = #control_field_response{ }}}->
      ?LOGWARNING("unexpected response frame received 2 ~p",[ Unexpected ] ),
      loop( Data );
    {data, Port, #frame{ control_field =  CF, data = UserData }} ->
      case check_fcb( CF, FCB ) of
        {ok, NextFCB} ->
          Data1 = handle_request( CF#control_field_request.function_code, UserData, Data ),
          loop( Data1#data{ in_fcb = NextFCB } );
        error->
          ?LOGWARNING("check fcb error, cf ~p, FCB ~p",[CF, FCB]),
          case SentFrame of
            #frame{}-> iec60870_ft12:send( Port, SentFrame );
            _-> ignore
          end,
          loop( Data )
      end;
    {asdu, Connection, ASDU}->
      case transaction(?USER_DATA_CONFIRM, ASDU, Data ) of
        #data{} = Data1 ->
          loop( Data1 );
        error ->
          exit( transaction_error )
      end;
    {stop, Owner }->
      iec60870_ft12:stop( port )
  end.

transaction(FC, Data)->
  transaction(FC, undefined, Data).
transaction(FC, UserData, #data{
  attempts = Attempts
} =Data)->
  transaction(Attempts, FC, UserData, Data).
transaction(Attempts, FC, UserData, #data{
  port = Port,
  address = Address,
  out_fcb = FCB,
  dir = Dir,
  timeout = Timeout
}=Data) when Attempts > 0->

  iec60870_ft12:send( Port, #frame{
    address = Address,
    control_field = #control_field_request{
      direction = Dir,
      fcb = ?NOT( FCB ),
      fcv = fcv( FC ),
      function_code = FC
    },
    data = UserData
  }),

  ResponseFC = response_fc( FC ),

  case wait_acknowledge(Timeout, ResponseFC, Data) of
    #data{} = Data1 ->
      Data1#data{ out_fcb = ?NOT(FCB) };
    error->
      transaction( Attempts - 1, FC, UserData, Data )
  end;
transaction(_Attempts, _FC, _UserData, _Data)->
  error.

wait_acknowledge(_Timeout, undefined, Data)->
  Data;
wait_acknowledge(Timeout, FC,  #data{
  port = Port,
  address = Address,
  dir = Dir
} = Data) when Timeout > 0->
  T0 = ?TS,
  receive
    {data, Port, ?RESPONSE( Address, Dir, FC )}->
      Data;
    {data, Port, #frame{ address = ReqAddress } = Unexpected} when ReqAddress =/= Address->
      ?LOGWARNING("unexpected address frame received ~p",[ Unexpected ] ),
      wait_acknowledge( Timeout - ?DUR(T0), FC, Data );
    {data, Port, #frame{ control_field = #control_field_response{} } = Unexpected}->
      ?LOGWARNING("unexpected response frame received 3 ~p",[ Unexpected ] ),
      wait_acknowledge( Timeout - ?DUR(T0), FC, Data );
    {data, Port, #frame{ control_field = CF, data = UserData }}->
      Data1 = handle_request( CF#control_field_request.function_code, UserData, Data ),
      wait_acknowledge( Timeout - ?DUR(T0), FC, Data1 )
  after
    Timeout-> error
  end;
wait_acknowledge(_Timeout, _FC, _Data)->
  error.

fcv( FC )->
  case FC of
    ?LINK_TEST -> 1;
    ?USER_DATA_CONFIRM -> 1;
    _-> 0
  end.

response_fc( FC )->
  case FC of
    ?USER_DATA_NO_REPLY -> undefined;
    ?ACCESS_DEMAND -> ?STATUS_LINK_ACCESS_DEMAND;
    ?REQUEST_STATUS_LINK -> ?STATUS_LINK_ACCESS_DEMAND;
    _-> ?ACKNOWLEDGE
  end.

check_fcb( #control_field_request{ fcv = 0, fcb = _ReqFCB } , _FCB )->
  {ok, 0};  % TODO. Is itv wright to handled fcv = 0 as reset?
check_fcb( #control_field_request{ fcv = 1, fcb = FCB } , FCB )->
  error;
check_fcb( #control_field_request{ fcv = 1, fcb = RecFCB } , _FCB )->
  {ok, RecFCB}.


handle_request(?RESET_REMOTE_LINK, _UserData, #data{
  port = Port,
  address = Address,
  dir = Dir
} = Data)->

  Data#data{
    sent_frame = send_response( Port, ?ACKNOWLEDGE_FRAME(Address, ?NOT(Dir)) )
  };

handle_request(?RESET_USER_PROCESS, _UserData, #data{
  port = Port,
  address = Address,
  dir = Dir
} = Data)->

  % TODO. Do we need to do anything? May be restart connection?
  Data#data{
    sent_frame = send_response( Port, ?ACKNOWLEDGE_FRAME(Address, ?NOT(Dir)) )
  };

handle_request(?USER_DATA_CONFIRM, ASDU, #data{
  connection = Connection,
  port = Port,
  address = Address,
  dir = Dir
} = Data)->

  if
    is_pid( Connection )->
      Connection ! { asdu, self(), ASDU };
    true ->
      ignore
  end,

  Data#data{
    sent_frame = send_response( Port, ?ACKNOWLEDGE_FRAME(Address, ?NOT(Dir)) )
  };

handle_request(?USER_DATA_NO_REPLY, ASDU, #data{
  connection = Connection
} = Data)->
  if
    is_pid( Connection )->
      Connection ! { asdu, self(), ASDU };
    true ->
      ?LOGWARNING("user data received on not initialized connection ~p",[ ASDU ] )
  end,
  Data;

handle_request(?ACCESS_DEMAND, _UserData, #data{
  port = Port,
  address = Address,
  dir = Dir
} = Data)->
  Data#data{
    sent_frame = send_response( Port, #frame{
      address = Address,
      control_field = #control_field_response{
        direction = ?NOT(Dir),
        acd = 0,
        dfc = 0,
        function_code = ?STATUS_LINK_ACCESS_DEMAND
      }
    })
  };

handle_request(?REQUEST_STATUS_LINK, _UserData, #data{
  port = Port,
  address = Address,
  dir = Dir
} = Data)->

  Data#data{
    sent_frame = send_response( Port, ?ACKNOWLEDGE_FRAME(Address, ?NOT(Dir)) )
  };

handle_request(InvalidFC, _UserData, Data)->
  ?LOGERROR("invalid request function code received ~p",[ InvalidFC ]),
  Data.


send_response(Port, Frame )->
  iec60870_ft12:send(Port, Frame),
  Frame.
