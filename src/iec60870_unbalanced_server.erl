-module(iec60870_unbalanced_server).

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

-define(ACKNOWLEDGE_FRAME(Address), #frame{
  address = Address,
  control_field = #control_field_response{
    direction = 0,
    acd = 0,
    dfc = 0,
    function_code = ?ACKNOWLEDGE
  }
}).

-record(data, {
  root,
  address,
  switch,
  fcb,
  sent_frame,
  connection
}).

%% +--------------------------------------------------------------+
%% |                             API                              |
%% +--------------------------------------------------------------+

start(Root, Options) ->
  PID = spawn_link(fun() -> init(Root, Options) end),
  receive
    {ready, PID} ->
      PID;
    {'EXIT', PID, Reason} ->
      ?LOGERROR("connection is down due to an error: ~p", [Reason]),
      throw(Reason)
  end.

stop(PID) ->
  PID ! {stop, self()}.

%% +--------------------------------------------------------------+
%% |                      Internal functions                      |
%% +--------------------------------------------------------------+

init(Root, #{
  address := Address
} = Options) ->
  Switch = iec60870_switch:start(Options),
  %% TODO: We should start connection before returning ready, not vice versa.
  Root ! {ready, self()},
  Connection =
    case iec60870_server:start_connection(Root, {?MODULE, self()}, self()) of
      {ok, NewConnection} ->
        erlang:monitor(process, NewConnection),
        NewConnection;
      error ->
        exit(server_stm_start_failed)
    end,
  loop(#data{
    root = Root,
    address = Address,
    switch = Switch,
    connection = Connection,
    fcb = undefined
  }).

loop(#data{
  root = Root,
  switch = Switch,
  address = Address,
  fcb = FCB,
  sent_frame = SentFrame,
  connection = Connection
} = Data) ->
  receive
    {data, Switch, #frame{address = ReqAddress}} when ReqAddress =/= Address ->
      ?LOGWARNING("received unexpected data link address: ~p", [ReqAddress]),
      loop(Data);
    {data, Switch, Unexpected = #frame{control_field = #control_field_response{}}}->
      ?LOGWARNING("unexpected response frame received ~p", [Unexpected]),
      loop(Data);
    {data, Switch, #frame{control_field = CF, data = UserData}} ->
      case check_fcb(CF, FCB) of
        {ok, NextFCB} ->
          Data1 = handle_request(CF#control_field_request.function_code, UserData, Data),
          loop(Data1#data{fcb = NextFCB});
        error->
          ?LOGWARNING("check fcb error, cf ~p, FCB ~p", [CF, FCB]),
          case SentFrame of
            #frame{} -> send_response(Switch, SentFrame);
            _ -> ignore
          end,
          loop(Data)
      end;
    {'DOWN', _, process, Connection, _Error} ->
      ?LOGWARNING("server connection is down"),
      loop(Data#data{connection = undefined});
    {stop, Root} ->
      ?LOGWARNING("server has been terminated by the owner")
  end.

check_fcb(#control_field_request{fcv = 0, fcb = _ReqFCB} , _FCB) ->
  {ok, 0}; %% TODO. Is it correct to treat fcv = 0 as a reset?
check_fcb(#control_field_request{fcv = 1, fcb = FCB} , FCB) ->
  error;
check_fcb(#control_field_request{fcv = 1, fcb = RecFCB} , _FCB) ->
  {ok, RecFCB}.

handle_request(?RESET_REMOTE_LINK, _UserData, #data{
  switch = Switch,
  address = Address
} = Data) ->
  Data#data{
    sent_frame = send_response(Switch, ?ACKNOWLEDGE_FRAME(Address))
  };

handle_request(?RESET_USER_PROCESS, _UserData, #data{
  switch = Switch,
  address = Address
} = Data)->
  % TODO. Do we need to do anything? May be restart connection?
  Data#data{
    sent_frame = send_response(Switch, ?ACKNOWLEDGE_FRAME(Address))
  };

handle_request(?USER_DATA_CONFIRM, ASDU, #data{
  connection = Connection,
  switch = Switch,
  address = Address
} = Data) ->
  if
    is_pid(Connection) ->
      Connection ! {asdu, self(), ASDU},
      Data#data{
        sent_frame = send_response(Switch, ?ACKNOWLEDGE_FRAME(Address))
      };
    true ->
      ?LOGWARNING("user data with confirm frame type received on no longer alive connection ~p", [ASDU]),
      Data
  end;

handle_request(?USER_DATA_NO_REPLY, ASDU, #data{
  connection = Connection
} = Data) ->
  if
    is_pid(Connection) ->
      Connection ! {asdu, self(), ASDU};
    true ->
      ?LOGWARNING("user data with no reply frame type received on no longer alive connection ~p", [ASDU])
  end,
  Data;

handle_request(?ACCESS_DEMAND, _UserData, #data{
  switch = Switch,
  address = Address
} = Data)->
  Data#data{
    sent_frame = send_response(Switch, #frame{
      address = Address,
      control_field = #control_field_response{
        direction = 0,
        acd = 0,
        dfc = 0,
        function_code = ?STATUS_LINK_ACCESS_DEMAND
      }
    })
  };

handle_request(?REQUEST_STATUS_LINK, _UserData, #data{
  switch = Switch,
  address = Address,
  connection = Connection
} = Data) ->
  if
    is_pid(Connection) ->
      ?LOGINFO("server on port ~p received request for status link...", [Switch]),
      Data#data{
        connection = Connection,
        sent_frame = send_response(Switch, #frame{
          address = Address,
          control_field = #control_field_response{
            direction = 0,
            acd = 0,
            dfc = 0,
            function_code = ?STATUS_LINK_ACCESS_DEMAND
          }
        })
      };
    true ->
      ?LOGWARNING("request status link received on no longer alive connection"),
      Data
  end;

handle_request(?REQUEST_DATA_CLASS_1, _UserData, #data{
  switch = Switch,
  address = Address
} = Data) ->
  Data#data{
    sent_frame = send_response(Switch, #frame{
      address = Address,
      control_field = #control_field_response{
        direction = 0,
        acd = 0,
        dfc = 0,
        function_code = ?NACK_DATA_NOT_AVAILABLE
      }
    })
  };

handle_request(?REQUEST_DATA_CLASS_2, UserData, #data{
  switch = Switch,
  address = Address,
  connection = Connection
} = Data) ->
  if
    is_pid(Connection) ->
      Response =
        case check_data(Connection) of
          {ok, ConnectionData} ->
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
          _ ->
            %% Data isn't available
            #frame{
              address = Address,
              control_field = #control_field_response{
                direction = 0,
                acd = 0,
                dfc = 0,
                function_code = ?NACK_DATA_NOT_AVAILABLE
              }
            }
        end,
      Data#data{
        sent_frame = send_response(Switch, Response)
      };
    true ->
      ?LOGWARNING("data class 2 request received on no longer alive connection ~p", [UserData]),
      Data
  end;

handle_request(InvalidFC, _UserData, Data) ->
  ?LOGERROR("invalid request function code received ~p", [InvalidFC]),
  Data.

send_response(Switch, Frame) ->
  Switch ! {send, self(), Frame},
  Frame.

check_data(Connection) ->
  receive
    {asdu, Connection, Data} -> {ok, Data}
  after
    0 -> undefined
  end.