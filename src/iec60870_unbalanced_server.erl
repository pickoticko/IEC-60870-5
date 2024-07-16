%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_unbalanced_server).

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

-define(CONNECTION_TIMEOUT, 300000). % 5 min

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
  name,
  root,
  address,
  switch,
  fcb,
  sent_frame,
  connection
}).

%% +--------------------------------------------------------------+
%% |                       API implementation                     |
%% +--------------------------------------------------------------+

start(Root, Options) ->
  PID = spawn_link(fun() -> init(Root, Options) end),
  receive
    {ready, PID} ->
      PID;
    {'EXIT', PID, Reason} ->
      ?LOGERROR("server is down due to an error: ~p", [Reason]),
      throw(Reason)
  end.

stop(PID) ->
  PID ! {stop, self()}.

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init(Root, #{
  port := #{name := PortName},
  address := Address
} = Options) ->
  Switch = iec60870_switch:start(Options),
  iec60870_switch:add_server(Switch, Address),
  Root ! {ready, self()},
  Connection = start_connection(Root),
  loop(#data{
    name = PortName,
    root = Root,
    address = Address,
    switch = Switch,
    connection = Connection,
    fcb = undefined
  }).

start_connection(Root) ->
  case iec60870_server:start_connection(Root, {?MODULE, self()}, self()) of
    {ok, NewConnection} ->
      erlang:monitor(process, NewConnection),
      NewConnection;
    error ->
      exit(server_stm_start_failed)
  end.

loop(#data{
  name = Name,
  root = Root,
  switch = Switch,
  address = Address,
  fcb = FCB,
  sent_frame = SentFrame,
  connection = Connection
} = Data) ->
  receive
    {data, Switch, #frame{address = ReqAddress}} when ReqAddress =/= Address ->
      ?LOGWARNING("server w/ link address ~p received unexpected link address: ~p", [Address, ReqAddress]),
      loop(Data);
    {data, Switch, Unexpected = #frame{control_field = #control_field_response{}}} ->
      ?LOGWARNING("server w/ link address ~p received unexpected response frame: ~p", [Address, Unexpected]),
      loop(Data);
    {data, Switch, Frame = #frame{control_field = CF, data = UserData}} ->
      ?LOGDEBUG("server ~p w/ address ~p: received frame: ~p", [Name, Address, Frame]),
      case check_fcb(CF, FCB) of
        {ok, NextFCB} ->
          Data1 = handle_request(CF#control_field_request.function_code, UserData, Data),
          loop(Data1#data{fcb = NextFCB});
        error ->
          ?LOGWARNING("server w/ link address ~p got check fcb error. CF: ~p, FCB: ~p", [Address, CF, FCB]),
          case SentFrame of
            #frame{} -> send_response(Switch, SentFrame);
            _ -> ignore
          end,
          loop(Data)
      end;
    {'DOWN', _, process, Connection, _Error} ->
      ?LOGWARNING("~p server w/ link address ~p is down", [Name, Address]),
      NewConnection = start_connection( Root ),
      loop(Data#data{connection = NewConnection});
    {'DOWN', _, process, Switch, SwitchError} ->
      ?LOGWARNING("~p server w/ link address ~p is down because of the switch error: ~p", [Name, Address, SwitchError]),
      exit( SwitchError );
    {stop, Root} ->
      ?LOGWARNING("server w/ link address ~p has been terminated by the owner", [Address])
  after
    ?CONNECTION_TIMEOUT->
      ?LOGDEBUG("server ~p w/ address ~p: connection timeout!", [Name, Address]),
      % TODO. Diagnostics. Connection. Last connection timeout w/ timestamp
      drop_queue(),
      loop(Data)
  end.

check_fcb(#control_field_request{fcv = 0, fcb = _ReqFCB}, _FCB) ->
  {ok, 0}; %% TODO. Is it correct to treat fcv = 0 as a reset?
check_fcb(#control_field_request{fcv = 1, fcb = FCB}, FCB) ->
  error;
check_fcb(#control_field_request{fcv = 1, fcb = RecFCB}, _FCB) ->
  {ok, RecFCB}.

handle_request(?RESET_REMOTE_LINK, _UserData, #data{
  switch = Switch,
  address = Address,
  name = Name
} = Data) ->
  % TODO. Diagnostics. Connection. Received RESET LINK w/ timestamp
  ?LOGDEBUG("server ~p w/ address ~p: received RESET LINK", [Name, Address]),
  Data#data{
    sent_frame = send_response(Switch, ?ACKNOWLEDGE_FRAME(Address))
  };

handle_request(?RESET_USER_PROCESS, _UserData, #data{
  switch = Switch,
  address = Address,
  name = Name
} = Data) ->
  % TODO. Diagnostics. Connection. Received RESET USER PROCESS w/ timestamp
  ?LOGDEBUG("server ~p w/ address ~p: received RESET USER PROCESS", [Name, Address]),
  drop_asdu(),
  Data#data{
    sent_frame = send_response(Switch, ?ACKNOWLEDGE_FRAME(Address))
  };

handle_request(?USER_DATA_CONFIRM, ASDU, #data{
  connection = Connection,
  switch = Switch,
  address = Address,
  name = Name
} = Data) ->
  % TODO. Diagnostics. Connection. Received USER DATA CONFIRM and timestamp
  ?LOGDEBUG("server ~p w/ address ~p: received USER DATA CONFIRM", [Name, Address]),
  Connection ! {asdu, self(), ASDU},
  Data#data{
    sent_frame = send_response(Switch, ?ACKNOWLEDGE_FRAME(Address))
  };

handle_request(?USER_DATA_NO_REPLY, ASDU, #data{
  connection = Connection,
  address = Address,
  name = Name
} = Data) ->
  ?LOGDEBUG("server ~p w/ address ~p: received USER DATA CONFIRM", [Name, Address]),
  Connection ! {asdu, self(), ASDU},
  Data;

handle_request(?ACCESS_DEMAND, _UserData, #data{
  switch = Switch,
  address = Address,
  name = Name
} = Data) ->
  % TODO. Diagnostics. Connection. Received ACCESS DEMAND w/ timestamp
  ?LOGDEBUG("server ~p w/ address ~p: received ACCESS DEMAND", [Name, Address]),
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
  name = Name
} = Data) ->
  % TODO. Diagnostics. Connection. Received REQUEST STATUS LINK w/ timestamp
  ?LOGDEBUG("server ~p w/ address ~p: received REQUEST STATUS LINK", [Name, Address]),
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

handle_request(RequestData, _UserData, #data{
  switch = Switch,
  address = Address,
  connection = Connection,
  name = Name
} = Data)
  when RequestData =:= ?REQUEST_DATA_CLASS_1;
       RequestData =:= ?REQUEST_DATA_CLASS_2 ->
  % TODO. Diagnostics. Connection. Received DATA CLASS REQUEST w/ timestamp
  Response =
    case check_data(Connection) of
      {ok, ConnectionData} ->
        ?LOGDEBUG("server ~p message queue: ~p", [Name, element(2,erlang:process_info(self(), message_queue_len))]),
        #frame{
          address = Address,
          control_field = #control_field_response{
            direction = 0,
            acd = 1,
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
  ?LOGDEBUG("server ~p w/ address ~p: received DATA CLASS REQUEST, our RESPONSE: ~p", [Name, Address, Response]),
  Data#data{
    sent_frame = send_response(Switch, Response)
  };

handle_request(InvalidFC, _UserData, #data{address = Address} = Data) ->
  ?LOGERROR("server w/ link address ~p received invalid request function code: ~p", [Address, InvalidFC]),
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

drop_asdu() ->
  receive
    {asdu, _Connection, _Data} -> drop_asdu()
  after
    0 -> ok
  end.

drop_queue() ->
  receive
    _Any -> drop_queue()
  after
    0 -> ok
  end.