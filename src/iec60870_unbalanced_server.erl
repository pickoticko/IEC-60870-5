
-module(iec60870_unbalanced_server).

-include("iec60870.hrl").
-include("ft12.hrl").

%% API
-export([
  check_options/1,
  start_link/1
]).

-define(ACKNOWLEDGE_FRAME(Address),#frame{
  address = Address,
  control_field = #control_field_response{
    direction = 0,
    acd = 0,
    dfc = 0,
    function_code = ?ACKNOWLEDGE
  }
}).

-record(data, {
  address,
  port,
  fcb,
  sent_frame,
  connection_options,
  connection
}).

check_options( Options )->
  % TODO
  Options.

start_link(Options) ->
  Self = self(),
  PID = spawn_link( fun() -> init(Self, Options) end),
  receive
    {ready, PID} -> PID;
    {'EXIT', PID, Reason} -> throw(Reason)
  end.

init(Owner, #{
  address := Address,
  connection_options := ConnectionOptions
} = Options) ->

  Port = iec60870_ft12:start_link( maps:with([ port, port_options, address_size ], Options) ),

  Owner ! { ready, self()},

  loop(#data{
    address = Address,
    port = Port,
    connection_options = ConnectionOptions,
    connection = undefined,
    fcb = undefined
  }).

loop(#data{
  port = Port,
  address = Address,
  fcb = FCB,
  sent_frame = SentFrame
} = Data) ->

  receive
    {data, Port, #frame{ address = ReqAddress }} when ReqAddress =/= Address ->
      loop( Data );
    {data, Port, Unexpected = #frame{ control_field = #control_field_response{ }}}->
      ?LOGWARNING("unexpected response frame received ~p",[ Unexpected ] ),
      loop( Data );
    {data, Port, #frame{ control_field =  CF, data = UserData }} ->
      case check_fcb( CF, FCB ) of
        {ok, NextFCB} ->
          Data1 = handle_request( CF#control_field_request.function_code, UserData, Data ),
          loop( Data1#data{ fcb = NextFCB } );
        error->
          iec60870_ft12:send( Port, SentFrame )
      end
  end.

check_fcb( #control_field_request{ fcv = 0, fcb = ReqFCB } , _FCB )->
  {ok, ReqFCB};
check_fcb( #control_field_request{ fcv = 1, fcb = FCB } , FCB )->
  error;
check_fcb( #control_field_request{ fcv = 1 } , FCB )->
  {ok, FCB}.


handle_request(?RESET_REMOTE_LINK, _UserData, #data{
  port = Port,
  address = Address
} = Data)->

  Data#data{
    sent_frame = send_response( Port, ?ACKNOWLEDGE_FRAME(Address) )
  };

handle_request(?RESET_USER_PROCESS, _UserData, #data{
  port = Port,
  address = Address
} = Data)->

  % TODO. Do we need to do anything? May be restart connection?
  Data#data{
    sent_frame = send_response( Port, ?ACKNOWLEDGE_FRAME(Address) )
  };

handle_request(?USER_DATA_CONFIRM, ASDU, #data{
  connection = Connection,
  port = Port,
  address = Address
} = Data)->
  if
    is_pid( Connection )->
      Connection ! { asdu, self(), ASDU },
      Data#data{
        sent_frame = send_response( Port, ?ACKNOWLEDGE_FRAME(Address) )
      };
    true ->
      ?LOGWARNING("user data received on not initialized connection ~p",[ UserData ] ),
      Data
  end;

handle_request(?USER_DATA_NO_REPLY, ASDU, #data{
  connection = Connection
} = Data)->
  if
    is_pid( Connection )->
      Connection ! { asdu, self(), ASDU };
    true ->
      ?LOGWARNING("user data received on not initialized connection ~p",[ UserData ] )
  end,
  Data;

handle_request(?ACCESS_DEMAND, _UserData, #data{
  port = Port,
  address = Address
} = Data)->
  Data#data{
    sent_frame = send_response( Port, #frame{
      address = Address,
      control_field = #control_field_response{
        direction = 0,
        acd = 0,
        dfc = 0,
        function_code = ?STATUS_LINK_ACCESS_DEMAND
      }
    } )
  };

handle_request(?REQUEST_STATUS_LINK, _UserData, #data{
  port = Port,
  address = Address,
  connection = Connection,
  connection_options = ConnectionOptions
} = Data)->

  if
    is_pid( Connection )-> exit( Connection, shutdown );
    true -> ignore
  end,

  try
    NewConnection = iec60870_server_stm:start_link( ConnectionOptions ),
    Data#data{
      connection = NewConnection,
      sent_frame = send_response( Port, ?ACKNOWLEDGE_FRAME(Address) )
    }
  catch
    _:Error ->
      ?LOGERROR("unable to start process for incoming connection request, error ~p",[ Error ]),

      Data#data{
        connection = NewConnection,
        sent_frame = send_response( Port, #frame{
          address = Address,
          control_field = #control_field_response{
            direction = 0,
            acd = 0,
            dfc = 0,
            function_code = ?ERR_NOT_FUNCTIONING
          }
        } )
      }
  end;

handle_request(?REQUEST_DATA_CLASS_1, _UserData, #data{
  port = Port,
  address = Address
} = Data)->
  Data#data{
    sent_frame = send_response( Port, #frame{
      address = Address,
      control_field = #control_field_response{
        direction = 0,
        acd = 0,
        dfc = 0,
        function_code = ?NACK_DATA_NOT_AVAILABLE
      }
    })
  };

handle_request(?REQUEST_DATA_CLASS_2, _UserData, #data{
  port = Port,
  address = Address,
  connection = Connection
} = Data)->
  Response =
    if
      is_pid(Connection) ->
        case check_data( Connection ) of
          {ok, ConnectionData}->
            #frame{
              address = Address,
              control_field = #control_field_response{
                direction = 0,
                acd = 0,
                dfc = 0,
                function_code = ?USER_DATA
              },
              data = ConnectionData
            };
          _->
            % Data not available
            #frame{
              address = Address,
              control_field = #control_field_response{
                direction = 0,
                acd = 0,
                dfc = 0,
                function_code = ?NACK_DATA_NOT_AVAILABLE
              }
            }
        end
    end,

  Data#data{
    sent_frame = send_response( Port, Response )
  };

handle_request(InvalidFC, _UserData, Data)->
  ?LOGERROR("invalid request function code received ~p",[ InvalidFC ]),
  Data.


send_response(Port, Frame )->
  iec60870_ft12:send(Port, Frame),
  Frame.

check_data( Connection )->
  receive
    {send, Connection, Data} -> {ok, Data}
  after
    0-> undefined
  end.