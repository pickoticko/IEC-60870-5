%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_client_stm).
-behaviour(gen_statem).

-include("iec60870.hrl").
-include("asdu.hrl").

%%% +--------------------------------------------------------------+
%%% |                            OTP API                           |
%%% +--------------------------------------------------------------+

-export([
  callback_mode/0,
  code_change/3,
  init/1,
  handle_event/4,
  terminate/3
]).

%%% +---------------------------------------------------------------+
%%% |                         Macros & Records                      |
%%% +---------------------------------------------------------------+

%% All client states
-define(CONNECTING, connecting).
-define(CONNECTED, connected).
-define(ACTIVATION, activation).
-define(WRITE, write).
-define(INIT_GROUPS, init_groups).
-define(GROUP_REQUEST, group_request).

-define(GROUP_REQUEST_ATTEMPTS, 1).

-record(data, {
  esubscribe,
  owner,
  name,
  storage,
  groups,
  connection,
  asdu,
  objects_counter
}).

%%% +--------------------------------------------------------------+
%%% |                  OTP behaviour implementation                |
%%% +--------------------------------------------------------------+

callback_mode() -> [
  handle_event_function,
  state_enter
].

init({Owner, #{
  name := Name,
  type := Type,
  connection := ConnectionSettings,
  groups := Groups
} = Settings}) ->
  Storage =
    ets:new(data_objects, [
      set,
      public,
      {read_concurrency, true},
      {write_concurrency, auto}
    ]),
  ASDU =
    iec60870_asdu:get_settings(maps:with(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings)),
  EsubscribePID =
    case esubscribe:start_link(Name) of
      {ok, PID} -> PID;
      {error, Reason} -> exit(Reason)
    end,
  {ok, {?CONNECTING, Type, ConnectionSettings}, #data{
    objects_counter = #{},
    esubscribe = EsubscribePID,
    owner = Owner,
    name = Name,
    storage = Storage,
    asdu = ASDU,
    groups = Groups
  }}.

%%% +--------------------------------------------------------------+
%%% |                      Connecting State                        |
%%% +--------------------------------------------------------------+

handle_event(
  enter,
  _PrevState,
  {?CONNECTING, _, _},
  _Data
) ->
  {keep_state_and_data, [{state_timeout, 0, connect}]};

handle_event(
  state_timeout,
  connect,
  {?CONNECTING, Type, Settings},
  #data{groups = Groups} = Data
) ->
  Module = iec60870_lib:get_driver_module(Type),
  try
    % Required groups goes first in the list
    SortedGroups =
      lists:sort(fun(A, _B) -> maps:get(required, A) =:= true end, Groups),
    Connection = Module:start_client(Settings),
    {next_state, {?INIT_GROUPS, SortedGroups}, Data#data{
      connection = Connection
    }}
  catch
    _Exception:Reason ->
      {stop, Reason, Data}
  end;

%%% +--------------------------------------------------------------+
%%% |                      Init Groups State                       |
%%% +--------------------------------------------------------------+

handle_event(
  enter,
  _PrevState,
  {?INIT_GROUPS, _},
  _Data
) ->
  {keep_state_and_data, [{state_timeout, 0, init}]};

handle_event(
  state_timeout,
  init,
  {?INIT_GROUPS, [Group | Rest]},
  Data
) ->
  Attempts = get_group_attempts(Group),
  {next_state, {?GROUP_REQUEST, update, Attempts, Group, {?INIT_GROUPS, Rest}}, Data};

handle_event(
  state_timeout,
  init,
  {?INIT_GROUPS, []},
  #data{
    owner = Owner,
    storage = Storage
  } = Data
) ->
  % All groups have been received, the cache is ready
  % and therefore we can return a reference to it
  Owner ! {ready, self(), Storage},
  {next_state, ?CONNECTED, Data};

%%% +--------------------------------------------------------------+
%%% |                        Group request                         |
%%% +--------------------------------------------------------------+

%% Starting group request
handle_event(
  enter,
  _PrevState,
  {?GROUP_REQUEST, update, _Attempts, _Group, _NextState},
  _Data
) ->
  {keep_state_and_data, [{state_timeout, 0, init}]};

%% Sending group request and starting timer for timeout
handle_event(
  state_timeout,
  init,
  {?GROUP_REQUEST, update, _Attempts, #{id := GroupID, timeout := Timeout}, _NextState},
  #data{connection = Connection, asdu = ASDUSettings} = Data
) ->
  [GroupRequest] = iec60870_asdu:build(#asdu{
    type = ?C_IC_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACT,
    objects = [{_IOA = 0, GroupID}]
  }, ASDUSettings),
  send_asdu(Connection, GroupRequest),
  {keep_state, Data#data{objects_counter = #{}}, [{state_timeout, Timeout, timeout}]};

%% Retrying to send the group request
handle_event(
  state_timeout,
  timeout,
  {?GROUP_REQUEST, update, Attempts, #{id := ID} = Group, NextState},
  Data
) when Attempts > 0 ->
  ?LOGWARNING("timeout of the group request, retrying by group ID: ~p", [ID]),
  {next_state, {?GROUP_REQUEST, update, Attempts - 1, Group, NextState}, Data};

%% No attempts left for the group request
handle_event(
  state_timeout,
  timeout,
  {?GROUP_REQUEST, update, _Attempts, #{id := ID, count := Count, required := true} = Group,
    {?INIT_GROUPS, _} = NextState},
  #data{objects_counter = Objects} = Data
) ->
  ?LOGWARNING("timeout of the required group request: ~p", [ID]),
  case check_received_objects(Objects, Count) of
    true ->
      start_group_request_timer(Group),
      {next_state, NextState, Data};
    false ->
      {stop, {group_request_timeout, ID}}
  end;

%% Except in the state INIT_GROUPS, all groups will be handled without crashing
handle_event(
  state_timeout,
  timeout,
  {?GROUP_REQUEST, update, _Attempts, #{id := ID} = Group, NextState},
  Data
) ->
  ?LOGWARNING("group request timeout: ~p, continuing without crash...", [ID]),
  start_group_request_timer(Group),
  {next_state, NextState, Data};

%%% +--------------------------------------------------------------+
%%% |                    Remote control command                    |
%%% +--------------------------------------------------------------+

%% Sending remote control request
handle_event(
  enter,
  _PrevState,
  {?WRITE, _From, IOA, #{type := Type} = Value},
  #data{connection = Connection, asdu = ASDUSettings}
) ->
  [ASDU] = iec60870_asdu:build(#asdu{
    type = Type,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACT,
    objects = [{IOA, Value}]
  }, ASDUSettings),
  send_asdu(Connection, ASDU),
  keep_state_and_data;

%% Timeout of the remote control
handle_event(
  state_timeout,
  _PrevState,
  {?WRITE, From, _, _},
  Data
) ->
  {next_state, ?CONNECTED, Data, [{reply, From, write_timeout}]};

%%% +--------------------------------------------------------------+
%%% |                          Connected                           |
%%% +--------------------------------------------------------------+

handle_event(
  enter,
  _PrevState,
  ?CONNECTED,
  _Data
) ->
  keep_state_and_data;

%% Event from timer for the group update is received
%% Changing state to the group request
handle_event(
  info,
  {update_group, Group, PID},
  ?CONNECTED,
  Data
) when PID =:= self() ->
  Attempts = get_group_attempts(Group),
  {next_state, {?GROUP_REQUEST, update, Attempts, Group, ?CONNECTED}, Data};

%% Handling call of remote control command
%% Note: we can only write in the CONNECTED state
handle_event(
  {call, From},
  {write, IOA, DataObject},
  State,
  Data
) ->
  case State =:= ?CONNECTED of
    true ->
      ?LOGWARNING("remote control request timeout, address: ~p, object: ~p", [IOA, DataObject]),
      {next_state, {?WRITE, From, IOA, DataObject}, Data, [{state_timeout, ?DEFAULT_WRITE_TIMEOUT, ?CONNECTED}]};
    false ->
      {keep_state_and_data, [{reply, From, {error, {connection_not_ready, State}}}]}
  end;

%%% +--------------------------------------------------------------+
%%% |                        Other events                          |
%%% +--------------------------------------------------------------+

%% Notify event from esubscribe
handle_event(
  info,
  {write, IOA, Value},
  _State,
  #data{
    name = Name,
    connection = Connection,
    asdu = ASDUSettings
  }
) ->
  % Getting all object updates
  NextItems = [Object || {Object, _Node, A} <- esubscribe:lookup(Name, update), A =/= self()],
  Items = [{IOA, Value} | NextItems],
  send_data_objects([{IOA, Value} | Items], Connection, ?COT_SPONT, ASDUSettings),
  keep_state_and_data;

%% Parsing incoming data objects
handle_event(
  info,
  {asdu, Connection, ASDU},
  State,
  #data{
    name = Name,
    connection = Connection,
    asdu = ASDUSettings
  } = Data
) ->
  try
    ParsedASDU = iec60870_asdu:parse(ASDU, ASDUSettings),
    handle_asdu(ParsedASDU, State, Data)
  catch
    _Exception:Reason ->
      case Reason of
        {invalid_object, _Value} ->
          {stop, Reason, Data};
        _Other ->
          ?LOGERROR("~p invalid data object (ASDU) received: ~p, reason: ~p", [Name, ASDU, Reason]),
          keep_state_and_data
      end
  end;

%% Failed send error received from the client connection
handle_event(
  info,
  {send_error, Connection, Error},
  _AnyState,
  #data{connection = Connection} = _Data
) ->
  ?LOGWARNING("client failed to send packet due to a reason: ~p", [Error]),
  keep_state_and_data;

%% If we receive updates on the group while in a state
%% other than the connected state, we will defer
%% processing them until the current event is completed
handle_event(
  info,
  {update_group, _, PID},
  _AnyState,
  _Data
) when PID =:= self() ->
  {keep_state_and_data, [postpone]};

handle_event(
  EventType,
  EventContent,
  _AnyState,
  _Data
) ->
  ?LOGWARNING("client connection received unexpected event type ~p, content ~p", [
    EventType,
    EventContent
  ]),
  keep_state_and_data.

terminate(Reason, _, _State = #data{esubscribe = PID}) when Reason =:= normal; Reason =:= shutdown ->
  exit(PID, shutdown),
  ?LOGWARNING("client connection terminated normally with a reason: ~p", [Reason]),
  ok;

terminate(Reason, _, _State) ->
  ?LOGWARNING("client connection terminated abnormally with a reason: ~p", [Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%% +--------------------------------------------------------------+
%%% |                     Data object handlers                     |
%%% +--------------------------------------------------------------+

%% Receiving information data objects
handle_asdu(#asdu{
  type = Type,
  objects = Objects,
  cot = COT
}, _State, #data{
  name = Name,
  storage = Storage,
  objects_counter = ObjectsCounter
} = Data)
  when (Type >= ?M_SP_NA_1 andalso Type =< ?M_ME_ND_1)
    orelse (Type >= ?M_SP_TB_1 andalso Type =< ?M_EP_TD_1)
    orelse (Type =:= ?M_EI_NA_1) ->
  Group = parse_group_cot(COT),
  % Saving received objects into counter map
  UpdatedObjectsCounter =
    lists:foldl(
      fun({IOA, Value}, AccIn) ->
        update_data_object(Name, Storage, IOA, Value#{type => Type, group => Group}),
        AccIn#{IOA => Value}
      end, ObjectsCounter, Objects),
  {keep_state, Data#data{objects_counter = UpdatedObjectsCounter}};

%%% +--------------------------------------------------------------+
%%% |                     Handling write request                   |
%%% +--------------------------------------------------------------+
%%% | Note: We do not expect that there will be a strict sequence  |
%%% | of responses from the server so, if we get activation        |
%%% | termination, then we assume that the write has succeeded     |
%%% +--------------------------------------------------------------+

handle_asdu(#asdu{
  type = Type,
  cot = COT,
  pn = PN,
  objects = [{IOA, _ }]
}, {?WRITE, From, IOA, #{type := Type} = _Value}, Data)
  when (Type >= ?C_SC_NA_1 andalso Type =< ?C_BO_NA_1) orelse
       (Type >= ?C_SC_TA_1 andalso Type =< ?C_BO_TA_1) ->
  case {COT, PN} of
    {?COT_ACTCON, ?POSITIVE_PN} -> keep_state_and_data;
    {?COT_ACTCON, ?NEGATIVE_PN} -> {next_state, ?CONNECTED, Data, [{reply, From, {error, negative_confirmation}}]};
    {?COT_ACTTERM, ?POSITIVE_PN} -> {next_state, ?CONNECTED, Data, [{reply, From, ok}]};
    {?COT_ACTTERM, ?NEGATIVE_PN} -> {next_state, ?CONNECTED, Data, [{reply, From, {error, negative_termination}}]}
  end;

%%% +--------------------------------------------------------------+
%%% |                     Handling group request                   |
%%% +--------------------------------------------------------------+

%% Confirmation of the group request
handle_asdu(#asdu{
  type = ?C_IC_NA_1,
  cot = ?COT_ACTCON,
  objects = [{_IOA, _GroupID}]
}, {?GROUP_REQUEST, update, _Attempts, _Group, _NextState}, _Data) ->
  keep_state_and_data;

%% Rejection of the group request
handle_asdu(#asdu{
  type = ?C_IC_NA_1,
  cot = COT,
  pn = ?NEGATIVE_PN,
  objects = [{_IOA, GroupID}]
}, {?GROUP_REQUEST, update, _Attempts, #{id := GroupID}, NextState}, Data) ->
  ?LOGWARNING("negative response on the group request, GroupID: ~p, COT ~p", [GroupID, COT]),
  case NextState of
    {?INIT_GROUPS, _} ->
      {stop, negative_pn_group_request, Data};
    _Other ->
      {next_state, NextState, Data}
  end;

%% Termination of the group request
handle_asdu(#asdu{
  type = ?C_IC_NA_1,
  cot = ?COT_ACTTERM,
  objects = [{_IOA, GroupID}]
}, {?GROUP_REQUEST, update, _Attempts, #{id := GroupID} = Group, NextState}, Data) ->
  start_group_request_timer(Group),
  {next_state, NextState, Data};

%% Time synchronization request
handle_asdu(#asdu{type = ?C_CS_NA_1, objects = Objects}, _State, #data{
  asdu = ASDUSettings,
  connection = Connection
}) ->
  [Confirmation] = iec60870_asdu:build(#asdu{
    type = ?C_CS_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_SPONT,
    objects = Objects
  }, ASDUSettings),
  send_asdu(Connection, Confirmation),
  keep_state_and_data;

%% All other unexpected asdu types
handle_asdu(#asdu{} = Unexpected, State, _Data) ->
  ?LOGWARNING("unexpected data object was received: ASDU: ~p, state: ~p", [Unexpected, State]),
  keep_state_and_data.

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

send_data_objects(Items, Connection, COT, ASDUSettings) ->
  TypedItems = group_objects_by_type(Items),
  [begin
     ASDUList = iec60870_asdu:build(#asdu{
       type = Type,
       pn = ?POSITIVE_PN,
       cot = COT,
       objects = Objects
     }, ASDUSettings),
     [send_asdu(Connection, ASDU) || ASDU <- ASDUList]
   end || {Type, Objects} <- TypedItems].

group_objects_by_type(Objects) ->
  group_objects_by_type(Objects, #{}).
group_objects_by_type([{IOA, #{type := Type} = Value} | Rest], Acc) ->
  TypeAcc = maps:get(Type,Acc,#{}),
  Acc1 = Acc#{Type => TypeAcc#{IOA => Value}},
  group_objects_by_type(Rest, Acc1);
group_objects_by_type([], Acc) ->
  [{Type, lists:sort(maps:to_list(Objects))} || {Type, Objects} <- maps:to_list(Acc)].

send_asdu(Connection, ASDU) ->
  Connection ! {asdu, self(), ASDU}, ok.

get_group_attempts(#{attempts := undefined}) ->
  ?GROUP_REQUEST_ATTEMPTS;
get_group_attempts(#{attempts := Value}) ->
  Value.

check_received_objects(Objects, MinCount) when is_integer(MinCount) ->
  maps:size(Objects) >= MinCount;
check_received_objects(_Objects, _MinCount) ->
  false.

parse_group_cot(COT)
  when COT >= ?COT_GROUP_MIN andalso COT =< ?COT_GROUP_MAX ->
    COT - ?COT_GROUP_MIN;
parse_group_cot(_COT) ->
  undefined.

start_group_request_timer(Group) ->
  case Group of
    #{update := UpdateCycle} when is_integer(UpdateCycle) ->
      timer:send_after(UpdateCycle, {update_group, Group, self()});
    _ ->
      ignore
  end.

update_data_object(Name, Storage, ID, InObject) ->
  OldObject =
    case ets:lookup(Storage, ID) of
      [{_, Map}] -> Map;
      _ -> #{
        value => undefined,
        group => undefined
      }
    end,
  NewObject = maps:merge(OldObject, InObject#{
    accept_ts => erlang:system_time(millisecond)
  }),
  ets:insert(Storage, {ID, NewObject}),
  % Any updates notification
  esubscribe:notify(Name, update, {ID, NewObject}),
  % Only address notification
  esubscribe:notify(Name, ID, NewObject).