-module(iec60870_client_stm).
-behaviour(gen_statem).

-include("iec60870.hrl").
-include("asdu.hrl").

%% +--------------------------------------------------------------+
%% |                           OTP API                            |
%% +--------------------------------------------------------------+

-export([
  callback_mode/0,
  code_change/3,
  init/1,
  handle_event/4,
  terminate/3
]).

%% +--------------------------------------------------------------+
%% |                           Macros                             |
%% +--------------------------------------------------------------+

-record(data, {
  esubscribe,
  owner,
  name,
  storage,
  groups,
  connection,
  asdu
}).

%% +--------------------------------------------------------------+
%% |                           States                             |
%% +--------------------------------------------------------------+

-define(CONNECTING, connecting).
-define(CONNECTED, connected).
-define(ACTIVATION, activation).
-define(WRITE, write).
-define(INIT_GROUPS, init_groups).
-define(GROUP_REQUEST, group_request).

%% +--------------------------------------------------------------+
%% |                   OTP gen_statem behaviour                   |
%% +--------------------------------------------------------------+

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
  Storage = ets:new(data_objects, [
    set,
    public,
    {read_concurrency, true},
    {write_concurrency, auto}
  ]),
  ASDU = iec60870_asdu:get_settings(maps:with(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings)),

  EsubscribePID =
    case esubscribe:start_link(Name) of
      {ok, PID} -> PID;
      {error, Reason} -> throw(Reason)
    end,

  {ok, {?CONNECTING, Type, ConnectionSettings}, #data{
    esubscribe = EsubscribePID,
    owner = Owner,
    name = Name,
    storage = Storage,
    asdu = ASDU,
    groups = Groups
  }}.

%% +--------------------------------------------------------------+
%% |                      Connecting State                        |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, {?CONNECTING, _, _}, _Data) ->
  {keep_state_and_data, [{state_timeout, 0, connect}]};

handle_event(state_timeout, connect, {?CONNECTING, Type, Settings}, #data{
  groups = Groups
} = Data) ->
  Module = iec60870_lib:get_driver_module(Type),
  Connection = Module:start_client(Settings),
  {next_state, {?INIT_GROUPS, Groups}, Data#data{
    connection = Connection
  }};

%% +--------------------------------------------------------------+
%% |                      Init Groups State                       |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, {?INIT_GROUPS, _}, _Data) ->
  {keep_state_and_data, [{state_timeout, 0, init}]};

handle_event(state_timeout, init, {?INIT_GROUPS, [Group | Rest]}, Data) ->
  {next_state, {?GROUP_REQUEST, init, Group, {?INIT_GROUPS, Rest}}, Data};

handle_event(state_timeout, init, {?INIT_GROUPS, []}, #data{
  owner = Owner,
  storage = Storage
} = Data) ->
  %% All groups have been received, the cache is ready
  %% and therefore we can return a reference to it
  Owner ! {ready, self(), Storage},
  {next_state, ?CONNECTED, Data};

%% +--------------------------------------------------------------+
%% |                        Group request                         |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, {?GROUP_REQUEST, init, #{id := GroupID}, _}, #data{
  connection = Connection,
  asdu = ASDUSettings
}) ->
  % TODO. Handle group versions
  [GroupRequest] = iec60870_asdu:build(#asdu{
    type = ?C_IC_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACT,
    objects = [{_IOA = 0, GroupID}]
  }, ASDUSettings),
  send_asdu(Connection, GroupRequest),
  keep_state_and_data;

handle_event(enter, _PrevState, {?GROUP_REQUEST, update, #{id := GroupID}, _}, #data{
  groups = Groups
}) ->
  Actions =
    case Groups of
      #{GroupID := #{timeout := Timeout }} when is_integer(Timeout)->
        [{state_timeout, Timeout, timeout}];
      _ ->
        []
    end,
  {keep_state_and_data, Actions};

handle_event(state_timeout, timeout, {?GROUP_REQUEST, update, #{id := ID}, _NextState}, _Data) ->
  {stop, {group_request_timeout, ID}};

%% +--------------------------------------------------------------+
%% |                Sending remote control command                |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, {?WRITE, _From, IOA, #{type := Type} = Value}, #data{
  connection = Connection,
  asdu = ASDUSettings
}) ->
  [ASDU] = iec60870_asdu:build(#asdu{
    type = Type,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACT,
    objects = [{IOA, Value}]
  }, ASDUSettings),
  send_asdu(Connection, ASDU),
  keep_state_and_data;

handle_event(state_timeout, _PrevState, {?WRITE, From, _, _}, Data) ->
  {next_state, ?CONNECTED, Data, [{reply, From, write_timeout}]};

%% +--------------------------------------------------------------+
%% |                          Connected                           |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, ?CONNECTED, _Data) ->
  keep_state_and_data;

%% Event from timer for the group update is received
%% Changing state to the group request
handle_event(info, {update_group, Group, PID}, ?CONNECTED, Data) when PID =:= self() ->
  {next_state, {?GROUP_REQUEST, init, Group, ?CONNECTED}, Data};

%% Handling call of remote control command
%% Note: we can only write in the CONNECTED state
handle_event({call, From}, {write, IOA, Value}, State, Data) ->
  if
    State =:= ?CONNECTED ->
      {next_state, {?WRITE, From, IOA, Value}, Data, [{state_timeout, ?DEFAULT_WRITE_TIMEOUT, ?CONNECTED}]};
    true ->
      {keep_state_and_data, [{reply, From, {error, connection_not_ready}}]}
  end;

%% +--------------------------------------------------------------+
%% |                        Other events                          |
%% +--------------------------------------------------------------+

%% Notify event from esubscriber
handle_event(info, {write, IOA, Value}, _State, #data{
  name = Name,
  connection = Connection,
  asdu = ASDUSettings
}) ->
  %% Getting all updates
  NextItems = [Object || {Object, _Node, A} <- esubscribe:lookup(Name, update), A =/= self()],
  Items = [{IOA, Value} | NextItems],
  send_items([{IOA, Value} | Items], Connection, ?COT_SPONT, ASDUSettings),
  keep_state_and_data;

%% Handling incoming ASDU packets
handle_event(info, {asdu, Connection, ASDU}, State, #data{
  name = Name,
  connection = Connection,
  asdu = ASDUSettings
} = Data) ->
  try
    ParsedASDU = iec60870_asdu:parse(ASDU, ASDUSettings),
    handle_asdu(ParsedASDU, State, Data)
  catch
    _:E ->
      ?LOGERROR("~p invalid ASDU received: ~p, error: ~p", [Name, ASDU, E]),
      keep_state_and_data
  end;

%% If we receive updates on the group while in a state
%% other than the connected state, we will defer
%% processing them until the current event is completed
handle_event(info, {update_group, _, PID}, _AnyState, _Data) when PID =:= self() ->
  {keep_state_and_data, [postpone]};

handle_event(EventType, EventContent, _AnyState, #data{name = Name}) ->
  ?LOGWARNING("Client connection ~p received unexpected event type ~p, content ~p", [
    Name, EventType, EventContent
  ]),
  keep_state_and_data.

terminate(Reason, _, _State = #data{esubscribe = PID}) when Reason =:= normal; Reason =:= shutdown ->
  exit(PID, shutdown),
  ?LOGDEBUG("client connection terminated. Reason: ~p", [Reason]),
  ok;

terminate(Reason, _, _State = #data{esubscribe = PID}) ->
  exit(PID, shutdown),
  ?LOGWARNING("client connection terminated. Reason: ~p", [Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% Receiving information data objects
handle_asdu(#asdu{
  type = Type,
  objects = Objects,
  cot = COT
}, _State, #data{
  name = Name,
  storage = Storage
})
  when (Type >= ?M_SP_NA_1 andalso Type =< ?M_ME_ND_1)
    orelse (Type >= ?M_SP_TB_1 andalso Type =< ?M_EP_TD_1)
    orelse (Type =:= ?M_EI_NA_1) ->
  Group =
    if
      COT >= ?COT_GROUP_MIN, COT =< ?COT_GROUP_MAX ->
        COT - ?COT_GROUP_MIN;
      true ->
        undefined
    end,
  [update_value(Name, Storage, IOA, Value#{type => Type, group => Group}) || {IOA, Value} <- Objects],
  keep_state_and_data;

%% +--------------------------------------------------------------+
%% |                     Handling write request                   |
%% +--------------------------------------------------------------+
%% | Note: We do not expect that there will be a strict sequence  |
%% | of responses from the server so, if we get activation        |
%% | termination, then we assume that the write has succeeded     |
%% +--------------------------------------------------------------+

handle_asdu(#asdu{
  type = Type,
  cot = COT,
  pn = PN,
  objects = [{IOA, _ }]
}, {?WRITE, From, IOA, #{type := Type} = _Value}, Data)
  when (Type >= ?C_SC_NA_1 andalso Type =< ?C_BO_NA_1)
    orelse (Type >= ?C_SC_TA_1 andalso Type =< ?C_BO_TA_1) ->
  case {COT, PN} of
    {?COT_ACTCON, ?POSITIVE_PN} -> keep_state_and_data;
    {?COT_ACTCON, ?NEGATIVE_PN} -> {next_state, ?CONNECTED, Data, [{reply, From, {error, negative_confirmation}}]};
    {?COT_ACTTERM, ?POSITIVE_PN} -> {next_state, ?CONNECTED, Data, [{reply, From, ok}]};
    {?COT_ACTTERM, ?NEGATIVE_PN} -> {next_state, ?CONNECTED, Data, [{reply, From, {error, negative_termination}}]};
    %% TODO: Temporary case clause (RAPTOR compatibility, SHOULD REMOVE IT)
    {RaptorCOT, ?POSITIVE_PN} when (RaptorCOT =:= 1) orelse (RaptorCOT =:= 20) ->
      {next_state, ?CONNECTED, Data, [{reply, From, ok}]};
    {_OtherCOT, ?NEGATIVE_PN} ->
      {next_state, ?CONNECTED, Data, [{reply, From, {error, negative_pn}}]}
  end;

%% +--------------------------------------------------------------+
%% |                     Handling group request                   |
%% +--------------------------------------------------------------+

%% Confirmation of the group request
handle_asdu(#asdu{
  type = ?C_IC_NA_1,
  cot = ?COT_ACTCON,
  objects = [{_IOA, GroupID}]
}, {?GROUP_REQUEST, init, #{id := GroupID} = Group, NextState}, Data) ->
  Actions =
    case Group of
      #{timeout := Timeout} when is_integer(Timeout) ->
        [{state_timeout, Timeout, timeout}];
      _ ->
        []
    end,
  {next_state, {?GROUP_REQUEST, update, Group, NextState}, Data, Actions};

%% Rejection of the group request
handle_asdu(#asdu{
  type = ?C_IC_NA_1,
  cot = COT,
  pn = ?NEGATIVE_PN,
  objects = [{_IOA, GroupID}]
}, {?GROUP_REQUEST, init, #{id := GroupID}, NextState}, Data) ->
  ?LOGWARNING("negative responce on group ~p request, cot ~p", [GroupID, COT]),
  {next_state, NextState, Data};

%% Termination of the group request
handle_asdu(#asdu{
  type = ?C_IC_NA_1,
  cot = ?COT_ACTTERM,
  objects = [{_IOA, GroupID}]
}, {?GROUP_REQUEST, update, #{id := GroupID} = Group, NextState}, Data) ->
  case Group of
    #{update := UpdateCycle} when is_integer(UpdateCycle) ->
      timer:send_after(UpdateCycle, {update_group, Group, self()});
    _ ->
      ignore
  end,
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
handle_asdu(#asdu{} = Unexpected, State, #data{name = Name}) ->
  ?LOGWARNING("~p unexpected ASDU type is received: ASDU ~p, state ~p", [Name, Unexpected, State]),
  keep_state_and_data.

send_items(Items, Connection, COT, ASDUSettings) ->
  TypedItems = group_by_types(Items),
  [begin
     ASDUList = iec60870_asdu:build(#asdu{
       type = Type,
       pn = ?POSITIVE_PN,
       cot = COT,
       objects = Objects
     }, ASDUSettings),
     [send_asdu(Connection, ASDU) || ASDU <- ASDUList]
   end || {Type, Objects} <- TypedItems].

group_by_types(Objects) ->
  group_by_types(Objects, #{}).
group_by_types([{IOA, #{type := Type} = Value} | Rest], Acc) ->
  TypeAcc = maps:get(Type,Acc,#{}),
  Acc1 = Acc#{Type => TypeAcc#{IOA => Value}},
  group_by_types(Rest, Acc1);
group_by_types([], Acc) ->
  [{Type, lists:sort(maps:to_list(Objects))} || {Type, Objects} <- maps:to_list(Acc)].

send_asdu(Connection, ASDU) ->
  Connection ! {asdu, self(), ASDU}, ok.

update_value(Name, Storage, ID, InValue) ->
  OldValue =
    case ets:lookup(Storage, ID) of
      [{_, Map}] -> Map;
      _ -> #{
        %% All object types have these keys
        value => undefined,
        group => undefined
      }
    end,
  NewValue = maps:merge(OldValue, InValue#{
    accept_ts => erlang:system_time(millisecond)
  }),
  ets:insert(Storage, {ID, NewValue}),
  % Any updates notification
  esubscribe:notify(Name, update, {ID, NewValue}),
  % Only address notification
  esubscribe:notify(Name, ID, NewValue).