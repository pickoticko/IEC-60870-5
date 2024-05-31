%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_101).

-include("iec60870.hrl").
-include("ft12.hrl").

%%% +--------------------------------------------------------------+
%%% |                       Server & Client API                    |
%%% +--------------------------------------------------------------+

-export([
  start_server/1,
  stop_server/1,
  start_client/1
]).

%%% +--------------------------------------------------------------+
%%% |                        Shared functions                      |
%%% +--------------------------------------------------------------+

-export([
  connect/4,
  transaction/4,
  send_receive/3
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

%% Master request codes
-define(RESET_REMOTE_LINK, 0).
-define(LINK_TEST, 2).
-define(REQUEST_STATUS_LINK, 9).
-define(REQUEST_DATA_CLASS_1, 10).
-define(REQUEST_DATA_CLASS_2, 11).

%% Slave request codes
-define(ACKNOWLEDGE, 0).
-define(USER_DATA_CONFIRM, 3).
-define(STATUS_LINK_ACCESS_DEMAND, 11).
-define(NOT(X), abs(X - 1)).

%% Connection settings
-define(REQUIRED, {?MODULE, required}).
-define(DEFAULT_SETTINGS, #{
  port => ?REQUIRED,
  balanced => ?REQUIRED,
  address => ?REQUIRED,
  port_options => #{
    baudrate => 9600,
    parity => 0,
    stopbits => 1,
    bytesize => 8
  },
  address_size => 1
}).

-record(state,{
  address,
  direction,
  send_receive,
  fcb,
  attempts
}).

%%% +--------------------------------------------------------------+
%%% |                    Server API implementation                 |
%%% +--------------------------------------------------------------+

start_server(InSettings) ->
  Settings = check_settings(maps:merge(?DEFAULT_SETTINGS, InSettings)),
  Module =
    case Settings of
      #{balanced := false} ->
        iec60870_unbalanced_server;
      _ ->
        iec60870_balanced_server
    end,
  Root = self(),
  Server = Module:start(Root, Settings),
  {Module, Server}.

stop_server({Module, Server})->
  Module:stop(Server).

%%% +--------------------------------------------------------------+
%%% |                    Client API implementation                 |
%%% +--------------------------------------------------------------+

start_client(InSettings) ->
  Settings = check_settings(maps:merge(?DEFAULT_SETTINGS, InSettings)),
  Module =
    case Settings of
      #{balanced := false} ->
        iec60870_unbalanced_client;
      _ ->
        iec60870_balanced_client
    end,
  Root = self(),
  Module:start(Root, Settings).

%%% +--------------------------------------------------------------+
%%% |               Shared functions implementation                |
%%% +--------------------------------------------------------------+

%% Connection transmission procedure initialization
connect(Address, Direction, SendReceive, Attempts) ->
  connect(#state{
    address = Address,
    direction = Direction,
    send_receive = SendReceive,
    fcb = undefined,
    attempts = Attempts
  }).

%% Connection transmission procedure
%% Sequence:
%%   1. Reset of remote link
%%   2. Request status of link
connect(#state{attempts = Attempts} = State) ->
  connect(Attempts, State).
connect(Attempts, #state{
  send_receive = SendReceive,
  address = Address
} = State) when Attempts > 0 ->
  case reset_link(State) of
    {ok, ResetState} ->
      Request = build_request(?REQUEST_STATUS_LINK, _Data = undefined, ResetState),
      case SendReceive(Request) of
        {ok, Response} ->
          case Response of
            #frame{
              control_field = #control_field_response{
                function_code = ?STATUS_LINK_ACCESS_DEMAND
              }
            } ->
              ?LOGINFO("DEBUG. REQUEST STATUS LINK to address ~p is OK!", [Address]),
              {ok, ResetState#state{fcb = 0}};
            _ ->
              ?LOGWARNING("unexpected response to reset link. Address: ~p Response: ~p Attempts: ~p", [
                Address,
                Response,
                Attempts - 1
              ]),
              connect(Attempts - 1, State)
          end;
        {error, Error} ->
          ?LOGWARNING("error while attempting to reset link. Address: ~p Error: ~p Attempts: ~p", [
            Address,
            Error,
            Attempts - 1
          ]),
          connect(Attempts - 1, State)
      end;
    Error ->
      Error
  end;
connect(_Attempts = 0, _State) ->
  {error, connect_error}.

%% Procedure of sending message initialization
transaction(FunctionCode, Data, OnResponseFun, #state{attempts = Attempts} = State)->
  transaction(Attempts, FunctionCode, Data, OnResponseFun, State).

%% Procedure of sending packet
transaction(Attempts, FunctionCode, Data, OnResponseFun, #state{
  send_receive = SendReceive
} = State) ->
  Request = build_request(FunctionCode, Data, State),
  case SendReceive(Request) of
    {ok, Response} ->
      case OnResponseFun(Response) of
        ok ->
          NewFCB = Request#frame.control_field#control_field_request.fcb,
          {ok, State#state{fcb = NewFCB}};
        error ->
          ?LOGWARNING("unexpected response to transaction. Request: ~p Response: ~p", [Request, Response]),
          retry(Attempts - 1, FunctionCode, Data, OnResponseFun, State, {unexpected_response, Response})
      end;
    {error, Error} ->
      ?LOGWARNING("transaction error. Request: ~p Error: ~p", [Request, Error]),
      retry(Attempts - 1, FunctionCode, Data, OnResponseFun, State, Error)
  end.

send_receive(Port, Request, Timeout) ->
  Address = Request#frame.address,
  ok = iec60870_ft12:send(Port, Request),
  receive
    {data, Port, Response} ->
      case Response of
        #frame{address = Address, control_field = #control_field_response{}} ->
          {ok, Response};
        _ ->
          ?LOGWARNING("invalid response received. Request: ~p, Response: ~p", [Request, Response]),
          {error, invalid_response}
      end
  after
    Timeout -> {error, timeout}
  end.

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

retry(Attempts, FC, Data, OnResponse, State, _Error) when Attempts > 0 ->
  case connect(State) of
    {ok, ReconnectState} ->
      transaction(Attempts, FC, Data, OnResponse, ReconnectState);
    Error ->
      Error
  end;
retry(0 = _Attempts, _FC, _Data, _OnResponse, _State, Error)->
  {error, Error}.

reset_link(#state{attempts = Attempts} = State) ->
  reset_link(Attempts, State).

reset_link(0 = _Attempts, _State) ->
  ?LOGERROR("reset link failed, no attempts left..."),
  {error, reset_link_error};
reset_link(Attempts, #state{
  address = Address,
  send_receive = SendReceive
} = State) ->
  Request = build_request(?RESET_REMOTE_LINK, _Data = undefined, State),
  case SendReceive(Request) of
    {ok, Response} ->
      case Response of
        #frame{address = Address, control_field = #control_field_response{function_code = ?ACKNOWLEDGE}} ->
          ?LOGINFO("DEBUG. RESET LINK to address ~p is OK!", [Address]),
          {ok, State#state{fcb = 0}};
        _ ->
          ?LOGWARNING("unexpected response to reset link. Address: ~p Response: ~p Attempts: ~p", [
            Address,
            Response,
            Attempts - 1
          ]),
          reset_link(Attempts - 1, State)
      end;
    {error, Error} ->
      ?LOGWARNING("error while attempting to reset link. Address: ~p Error: ~p Attempts: ~p", [
        Address,
        Error,
        Attempts - 1
      ]),
      reset_link(Attempts - 1, State)
  end.

%% Building a request frame (packet) to send
build_request(FunctionCode, UserData, #state{
  address = Address,
  direction = Direction,
  fcb = FCB
}) ->
  #frame{
    address = Address,
    control_field = #control_field_request{
      direction = Direction,
      fcb = handle_fcb(FunctionCode, FCB),
      fcv = handle_fcv(FunctionCode),
      function_code = FunctionCode
    },
    data = UserData
  }.

%% FCB - Frame count bit
%% Alternated between 0 to 1 for successive SEND / CONFIRM or
%% REQUEST / RESPOND transmission procedures
handle_fcb(FunctionCode, FCB) ->
  case FunctionCode of
    ?RESET_REMOTE_LINK   -> 0;
    ?REQUEST_STATUS_LINK -> 0;
    _ -> ?NOT(FCB)
  end.

%% FCV - Frame count bit valid
%% 1 - FCB is valid
%% 0 - FCB is invalid
handle_fcv(FunctionCode) ->
  case FunctionCode of
    ?REQUEST_DATA_CLASS_1 -> 1;
    ?REQUEST_DATA_CLASS_2 -> 1;
    ?USER_DATA_CONFIRM    -> 1;
    ?LINK_TEST            -> 1;
    _Other -> 0
  end.

check_settings(Settings) ->
  % TODO: Add settings validation
  Settings.