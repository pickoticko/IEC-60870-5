%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_101).

-include("iec60870.hrl").
-include("ft12.hrl").
-include("function_codes.hrl").

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
  connect/1,
  user_data_confirm/2,
  data_class/2
]).

%%% +--------------------------------------------------------------+
%%% |                       Macros & Records                       |
%%% +--------------------------------------------------------------+

-define(UPDATE_FCB(State, Request), State#state{fcb = Request#frame.control_field#control_field_request.fcb}).
-define(DEFAULT_MAX_MESSAGE_QUEUE, 1000).
-define(DEFAULT_IDLE_TIMEOUT, 30000).
-define(DEFAULT_CYCLE, 1000).
-define(REQUIRED, {?MODULE, required}).
-define(NOT(X), abs(X - 1)).

-define(UNBALANCED_CLIENT_SETTINGS, #{
  cycle => ?DEFAULT_CYCLE
}).

-define(DEFAULT_SETTINGS, #{
  balanced => ?REQUIRED,
  address => ?REQUIRED,
  address_size => ?REQUIRED,
  on_request => undefined,
  transport => #{
    name => undefined,
    baudrate => 9600,
    parity => 0,
    stopbits => 1,
    bytesize => 8
  }
}).

-record(state, {
  address,
  attempts,
  direction,
  fcb,
  portFT12,
  timeout,
  on_request
}).

%%% +--------------------------------------------------------------+
%%% |                    Server API implementation                 |
%%% +--------------------------------------------------------------+

start_server(Settings) ->
  Module =
    case Settings of
      #{balanced := false} ->
        iec60870_unbalanced_server;
      _Other ->
        iec60870_balanced_server
    end,
  OutSettings = check_settings(maps:merge(?DEFAULT_SETTINGS, Settings)),
  Root = self(),
  Server = Module:start(Root, OutSettings),
  {Module, Server}.

stop_server({Module, Server})->
  Module:stop(Server).

%%% +--------------------------------------------------------------+
%%% |                    Client API implementation                 |
%%% +--------------------------------------------------------------+

start_client(InSettings) ->
  {Module, Settings} =
    case InSettings of
      #{balanced := false} ->
        {iec60870_unbalanced_client, maps:merge(?UNBALANCED_CLIENT_SETTINGS, InSettings)};
      _Other ->
        {iec60870_balanced_client, InSettings}
    end,
  OutSettings = check_settings(maps:merge(?DEFAULT_SETTINGS, Settings)),
  Root = self(),
  Module:start(Root, OutSettings).

%%% +--------------------------------------------------------------+
%%% |               Shared functions implementation                |
%%% +--------------------------------------------------------------+

%% Connection transmission procedure initialization
connect(#{
  address := Address,
  attempts := Attempts,
  direction := Direction,
  portFT12 := PortFT12,
  timeout := Timeout,
  on_request := OnRequest
}) ->
  connect(#state{
    address = Address,
    attempts = Attempts,
    direction = Direction,
    fcb = undefined,
    portFT12 = PortFT12,
    timeout = Timeout,
    on_request = OnRequest
  });

%% Connection transmission procedure
%% Sequence:
%%   1. Reset of remote link
%%   2. Request status of link
connect(#state{attempts = Attempts} = State) ->
  connect(Attempts, State).
connect(Attempts, #state{
  address = Address
} = StateIn) when Attempts > 0 ->

%------------Step 1. Request link------------------------------------
  case request_status_link(StateIn) of
    error ->
      ?LOGWARNING("REQUEST STATUS LINK 1 is ERROR. Address: ~p", [Address]),
      connect(Attempts - 1, StateIn);
    StateRequestLink ->
%------------Step 2. Reset link------------------------------------
      % TODO: Diagnostic log: Request Status Link = true, Connected = true
      ?LOGDEBUG("REQUEST STATUS LINK 1 is OK. Address: ~p", [Address]),
      case reset_link( StateRequestLink ) of
        error ->
          ?LOGERROR("RESET LINK is ERROR. Address: ~p", [Address]),
          connect(Attempts - 1, StateIn);
        StateResetLink ->
%------------Step 3. Request link------------------------------------
          % TODO: Diagnostic log: Reset Link = true
          ?LOGDEBUG("RESET LINK is OK. Address: ~p", [Address]),
          case request_status_link( StateResetLink ) of
            error ->
              ?LOGWARNING("REQUEST STATUS LINK 2 is ERROR. Address: ~p", [Address]),
              connect(Attempts - 1, StateIn);
            StateConnected ->
              ?LOGDEBUG("REQUEST STATUS LINK 2. Address: ~p", [Address]),
              StateConnected
          end
      end
  end;
connect(_Attempts = 0, #state{
  address = Address
}) ->
  ?LOGERROR("CONNECT ERROR. Address: ~p", [Address]),
  error.

data_class(DataClassCode, #state{attempts = Attempts} = State) ->
  data_class(Attempts, DataClassCode, State).

user_data_confirm(ASDU, #state{attempts = Attempts} = State) ->
  user_data_confirm(Attempts, ASDU, State).

%%% +--------------------------------------------------------------+
%%% |                  Reset link request sequence                 |
%%% +--------------------------------------------------------------+

reset_link(#state{attempts = Attempts} = State) ->
  reset_link(Attempts, State).

reset_link(0 = _Attempts, _State) ->
  ?LOGERROR("no attempts left for the reset link..."),
  error;
reset_link(Attempts, #state{
  portFT12 = PortFT12,
  address = Address
} = State) ->
  Request = build_request(?RESET_REMOTE_LINK, _Data = undefined, State),
  iec60870_ft12:send(PortFT12, Request),
  case wait_response(?ACKNOWLEDGE, undefined, State) of
    {ok, _} ->
      State#state{fcb = 0};
    error ->
      ?LOGWARNING("FT12 ~p, address ~p: no response received for RESET LINK", [PortFT12, Address]),
      reset_link(Attempts - 1, State)
  end.

%%% +--------------------------------------------------------------+
%%% |                 Request status link sequence                 |
%%% +--------------------------------------------------------------+

request_status_link(#state{
  portFT12 = PortFT12,
  address = Address
} = State) ->
  Request = build_request(?REQUEST_STATUS_LINK, _Data = undefined, State),
  iec60870_ft12:send(PortFT12, Request),
  case wait_response(?STATUS_LINK_ACCESS_DEMAND, undefined, State) of
    {ok, _} ->
      State#state{fcb = 0};
    error ->
      ?LOGWARNING("FT12 port ~p, address ~p: no response received for REQUEST STATUS LINK", [PortFT12, Address]),
      error
  end.

%%% +--------------------------------------------------------------+
%%% |              User data confirm request sequence              |
%%% +--------------------------------------------------------------+

user_data_confirm(Attempts, ASDU, #state{
  portFT12 = PortFT12,
  address = Address
} = State) when Attempts > 0 ->
  Request = build_request(?USER_DATA_CONFIRM, ASDU, State),
  iec60870_ft12:send(PortFT12, Request),
  case wait_response(?ACKNOWLEDGE, undefined, State) of
    {ok, _} ->
      ?UPDATE_FCB(State, Request);
    error ->
      ?LOGWARNING("FT12 ~p, address ~p: no response received for USER DATA CONFIRM", [
        PortFT12,
        Address
      ]),
      user_data_confirm(Attempts - 1, ASDU, State)
  end;
user_data_confirm(_Attempts = 0, ASDU, #state{
  attempts = Attempts
} = State) ->
  retry(fun(NewState) -> user_data_confirm(Attempts, ASDU, NewState) end, State).

%%% +--------------------------------------------------------------+
%%% |                  Data class request sequence                 |
%%% +--------------------------------------------------------------+

data_class(Attempts, DataClassCode, #state{
  portFT12 = PortFT12,
  address = Address
} = State) when Attempts > 0 ->
  Request = build_request(DataClassCode, undefined, State),
  iec60870_ft12:send(PortFT12, Request),
  case wait_response(?USER_DATA, ?NACK_DATA_NOT_AVAILABLE, State) of
    {ok, #frame{control_field = #control_field_response{function_code = ?USER_DATA, acd = ACD}, data = ASDU}} ->
      NewState = ?UPDATE_FCB(State, Request),
      {NewState, ACD, ASDU};
    {ok, #frame{control_field = #control_field_response{function_code = ?NACK_DATA_NOT_AVAILABLE, acd = ACD}}} ->
      NewState = ?UPDATE_FCB(State, Request),
      {NewState, ACD, undefined};
    error ->
      ?LOGWARNING("FT12 ~p, address ~p: no response received for DATA CLASS REQUEST", [
        PortFT12,
        Address
      ]),
      data_class(Attempts - 1, DataClassCode, State)
  end;
data_class(_Attempts = 0, DataClassCode, #state{
  attempts = Attempts
} = State) ->
  retry(fun(NewState) -> data_class(Attempts, DataClassCode, NewState) end, State).

%%% +--------------------------------------------------------------+
%%% |                       Helper functions                       |
%%% +--------------------------------------------------------------+

wait_response(Response1, Response2, #state{
  portFT12 = PortFT12,
  address = Address,
  timeout = Timeout,
  on_request = OnRequest
} = State) ->
  receive
    {data, PortFT12, #frame{address = UnexpectedAddress}} when UnexpectedAddress =/= Address ->
      ?LOGWARNING("~p received unexpected address: ~p", [Address, UnexpectedAddress]),
      wait_response(Response1, Response2, State);
    {data, PortFT12, #frame{
      control_field = #control_field_response{function_code = ResponseCode}
    } = Response} when ResponseCode =:= Response1; ResponseCode =:= Response2 ->
      % TODO: Diagnostic. ASDU
      {ok, Response};
    {data, PortFT12, #frame{control_field = #control_field_request{}} = Frame} when is_function(OnRequest) ->
      ?LOGDEBUG("~p received request while waiting for response, request: ~p", [Address, Frame]),
      OnRequest(Frame),
      wait_response(Response1, Response2, State);
    {data, PortFT12, UnexpectedFrame} ->
      % TODO: Diagnostic. PortFT12, UnexpectedFrame
      ?LOGWARNING("~p received unexpected frame: ~p", [Address, UnexpectedFrame]),
      wait_response(Response1, Response2, State)
  after
    Timeout -> error
  end.

%% Retrying to connect and executing user-function
retry(Fun, State) ->
  case connect(State) of
    error -> error;
    NewState -> Fun(NewState)
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
  [begin
     case Value of
       ?REQUIRED ->
         throw({required, Key});
       _Exists ->
         check_setting(Setting)
     end
   end || {Key, Value} = Setting <- maps:to_list(Settings)],
  Settings.

check_setting({balanced, IsBalanced})
  when is_boolean(IsBalanced) -> ok;

check_setting({address, DataLinkAddress})
  when is_integer(DataLinkAddress) -> ok;

check_setting({address_size, DataLinkAddressSize})
  when is_integer(DataLinkAddressSize) -> ok;

check_setting({cycle, Cycle})
  when is_integer(Cycle) -> ok;

check_setting({attempts, Attempts})
  when is_integer(Attempts) -> ok;

check_setting({timeout, Timeout})
  when is_integer(Timeout) -> ok;

check_setting({on_request, OnRequest})
  when is_function(OnRequest) orelse OnRequest =:= undefined -> ok;

check_setting({transport, PortSettings})
  when is_map(PortSettings) -> ok;

check_setting(InvalidSetting) ->
  throw({invalid_setting, InvalidSetting}).