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

-record(data, {
  esubscribe,
  owner,
  name,
  storage,
  groups,
  connection,
  asdu,
  state_acc
}).

-record(gi, {
  state,
  id,
  timeout,
  update,
  count,
  required,
  attempts,
  rest
}).

-record(rc, {
  state,
  type,
  from,
  ioa,
  value
}).

%% States
-define(CONNECTING, connecting).
-define(CONNECTED, connected).
-define(ACTIVATION, activation).
-define(INIT_GROUPS, init_groups).
-define(GROUP_REQUEST, group_request).

%% Common constants
-define(CONFIRM_TIMEOUT, 10000).

%% Group request
-define(GI_DEFAULT_TIMEOUT, 60000).
-define(GI_DEFAULT_ATTEMPTS, 1).

%% Remote control
-define(RC_TIMEOUT, 10000).

-define(GI_STATE(G), #gi{
  state = confirm,
  id = maps:get(id, G),
  timeout = maps:get(timeout, G, ?GI_DEFAULT_TIMEOUT),
  update = maps:get(update, G, undefined),
  attempts = maps:get(attempts, G, ?GI_DEFAULT_ATTEMPTS),
  count = maps:get(count, G, undefined),
  required = maps:get(required, G, false),
  rest = []
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

  process_flag(trap_exit, true),

  Storage = ets:new(data_objects, [
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
  % Required groups goes first
  {ok, {?CONNECTING, Type, ConnectionSettings}, #data{
    esubscribe = EsubscribePID,
    owner = Owner,
    name = Name,
    storage = Storage,
    asdu = ASDU,
    groups = Groups
  }}.

%%% +--------------------------------------------------------------+
%%% |           Handling incoming ASDU packets                     |
%%% +--------------------------------------------------------------+

handle_event(
  info,
  {asdu, Connection, ASDU},
  _State,
  #data{name = Name, connection = Connection, asdu = ASDUSettings} = Data
) ->
  try
    ParsedASDU = iec60870_asdu:parse(ASDU, ASDUSettings),
    {keep_state_and_data, [{next_event, internal, ParsedASDU}]}
  catch
    _:{invalid_object, _Value} = Error ->
      {stop, Error, Data};
    _:Error ->
      ?LOGERROR("~p invalid ASDU received: ~p, error: ~p", [Name, ASDU, Error]),
      keep_state_and_data
  end;

%%% +--------------------------------------------------------------+
%%% |                      Connecting State                        |
%%% +--------------------------------------------------------------+

handle_event(
  enter,
  _PrevState,
  {?CONNECTING, _, _},
  #data{name = Name} = _Data
) ->
  ?LOGDEBUG("client ~p: entering CONNECTING state", [Name]),
  {keep_state_and_data, [{state_timeout, 0, connect}]};

handle_event(
  state_timeout,
  connect,
  {?CONNECTING, Type, Settings},
  Data
) ->
  Module = iec60870_lib:get_driver_module(Type),
  try
    Connection = Module:start_client(Settings),
    erlang:monitor(process, Connection),
    {next_state, ?INIT_GROUPS, Data#data{
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
  ?INIT_GROUPS,
  #data{name = Name} = _Data
) ->
  ?LOGDEBUG("client ~p: entering INIT GROUPS state", [Name]),
  {keep_state_and_data, [{state_timeout, 0, init}]};

handle_event(
  state_timeout,
  init,
  ?INIT_GROUPS,
  #data{owner = Owner, storage = Storage, groups = Groups} = Data
) ->
  GIs = [?GI_STATE(G) || G <- Groups],
  % Init update events for not required groups. They are handled in the normal mode
  [self() ! GI || GI = #gi{required = false} <- GIs],
  % Get required groups
  Required = [GI || GI = #gi{required = true} <- GIs],
  case Required of
    [G | Rest] ->
      {next_state, G#gi{rest = Rest}, Data};
    _ ->
      Owner ! {ready, self(), Storage},
      {next_state, ?CONNECTED, Data}
  end;

%%% +--------------------------------------------------------------+
%%% |                        Group Interrogation                   |
%%% +--------------------------------------------------------------+

%% Sending group request and starting timer for confirmation
handle_event(
  enter,
  _PrevState,
  #gi{state = confirm, id = ID},
  #data{name = Name, asdu = ASDUSettings, connection = Connection}
) ->
  ?LOGDEBUG("client ~p: sending GI REQUEST for group ~p", [Name, ID]),
  [GroupRequest] = iec60870_asdu:build(#asdu{
    type = ?C_IC_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACT,
    objects = [{_IOA = 0, ID}]
  }, ASDUSettings),
  send_asdu(Connection, GroupRequest),
  {keep_state_and_data, [{state_timeout, ?CONFIRM_TIMEOUT, timeout}]};

%% GI Confirm
handle_event(
  internal,
  #asdu{type = ?C_IC_NA_1, cot = ?COT_ACTCON, pn = ?POSITIVE_PN, objects = [{_IOA, ID}]},
  #gi{state = confirm, id = ID} = State,
  #data{name = Name} = Data
) ->
  ?LOGDEBUG("client ~p: received GI CONFIRMATION for group ~p", [Name, ID]),
  {next_state, State#gi{state = run}, Data};

%% GI Reject
handle_event(
  internal,
  #asdu{type = ?C_IC_NA_1, cot = ?COT_ACTCON, pn = ?NEGATIVE_PN, objects = [{_IOA, ID}]},
  #gi{state = confirm, id = ID} = State,
  #data{name = Name} = Data
) ->
  ?LOGWARNING("~p, group interrogation ~p rejected", [Name, ID]),
  {next_state, State#gi{state = error}, Data};

handle_event(
  state_timeout,
  timeout,
  #gi{state = confirm, id = ID} = State,
  #data{name = Name} = Data
) ->
  ?LOGWARNING("~p, group ~p interrogation confirmation timeout", [Name, ID]),
  {next_state, State#gi{state = error}, Data};

%% GI Running
handle_event(
  enter,
  _PrevState,
  #gi{state = run, timeout = Timeout, id = ID},
  #data{name = Name} = Data
) ->
  ?LOGDEBUG("client ~p: entering GI RUN state for group ~p", [Name, ID]),
  {keep_state, Data#data{state_acc = #{}}, [{state_timeout, Timeout, timeout}]};

%% Update received
handle_event(
  internal,
  #asdu{type = Type, objects = Objects, cot = COT} = ASDU,
  #gi{state = run, id = ID},
  #data{name = Name, storage = Storage, state_acc = GroupItems0} = Data
) when (COT - ?COT_GROUP_MIN) =:= ID ->
  ?LOGDEBUG("client ~p: received GI for group ~p update ASDU: ~p", [Name, ID, ASDU]),
  GroupItems =
    lists:foldl(
      fun({IOA, Value}, AccIn) ->
        update_value(Name, Storage, IOA, Value#{type => Type, group => ID}),
        AccIn#{IOA => Value}
      end, GroupItems0, Objects),
  {keep_state, Data#data{state_acc = GroupItems}};

%% GI Termination (Completed)
handle_event(
  internal,
  #asdu{type = ?C_IC_NA_1, cot = ?COT_ACTTERM, pn = ?POSITIVE_PN, objects = [{_IOA, ID}]},
  #gi{state = run, id = ID, count = Count} = State,
  #data{name = Name, state_acc = GroupItems} = Data
) ->
  ?LOGDEBUG("client ~p: received GI TERMINATION for group ~p", [Name, ID]),
  IsSuccessful =
    if
      is_number(Count) -> map_size(GroupItems) >= Count;
      true -> true
    end,
  if
    IsSuccessful ->
      {next_state, State#gi{state = finish}, Data};
    true ->
      {next_state, State#gi{state = error}, Data}
  end;

%% Interrupted
handle_event(
  internal,
  #asdu{type = ?C_IC_NA_1, cot = ?COT_ACTTERM, pn = ?NEGATIVE_PN, objects = [{_IOA, ID}]},
  #gi{state = run, id = ID} = State,
  Data
) ->
  {next_state, State#gi{state = error}, Data};

handle_event(
  state_timeout,
  timeout,
  #gi{state = run, count = Count} = State,
  #data{state_acc = GroupItems} = Data
) ->
  IsSuccessful = is_number(Count) andalso (map_size(GroupItems) >= Count),
  if
    IsSuccessful ->
      {next_state, State#gi{state = finish}, Data};
    true ->
      {next_state, State#gi{state = error}, Data}
  end;

%% GI Error (Timeout)
handle_event(
  enter,
  _PrevState,
  #gi{state = error, id = ID},
  #data{name = Name} = _Data
) ->
  ?LOGDEBUG("client ~p: entering GI TIMEOUT for group ~p", [Name, ID]),
  {keep_state_and_data, [{state_timeout, 0, timeout}]};

handle_event(
  state_timeout,
  timeout,
  #gi{state = error, id = ID, required = Required, attempts = Attempts} = State,
  #data{name = Name} = Data
) ->
  RestAttempts = Attempts - 1,
  ?LOGDEBUG("client ~p: GI attempts for group ~p left: ~p", [Name, ID, RestAttempts]),
  if
    RestAttempts > 0 ->
      {next_state, State#gi{state = confirm, attempts = RestAttempts}, Data};
    Required =:= true ->
      {stop, {group_interrogation_error, ID}};
    true ->
      {next_state, State#gi{state = finish}, Data}
  end;

%% GI finish
handle_event(
  enter,
  _PrevState,
  #gi{state = finish, id = ID},
  _Data
) ->
  ?LOGDEBUG("client ~p: entering GI FINISH for group ~p", [ID]),
  {keep_state_and_data, [{state_timeout, 0, timeout}]};

handle_event(
  state_timeout,
  timeout,
  #gi{state = finish, update = Update, rest = RestGI, required = IsRequired} = State,
  #data{owner = Owner, storage = Storage} = Data
) ->
  case {IsRequired, RestGI} of
    {true, []} ->
      Owner ! {ready, self(), Storage};
    _ ->
      ignore
  end,
  % If the group must be cyclically updated queue the event
  if
    is_integer(Update) ->
      timer:send_after(Update, State#gi{state = confirm, required = false, rest = []});
    true ->
      ignore
  end,
  case RestGI of
    [NextGI | Rest] ->
      {next_state, NextGI#gi{rest = Rest}, Data};
    _ ->
      {next_state, ?CONNECTED, Data#data{state_acc = undefined}}
  end;

%%% +--------------------------------------------------------------+
%%% |                          Connected                           |
%%% +--------------------------------------------------------------+

handle_event(
  enter,
  _PrevState,
  ?CONNECTED,
  #data{name = Name} = _Data
) ->
  ?LOGDEBUG("client ~p: entering CONNECTED state", [Name]),
  keep_state_and_data;

handle_event(
  info,
  {write, IOA, Value},
  ?CONNECTED,
  #data{name = Name, connection = Connection, asdu = ASDUSettings}
) ->
  % Getting all updates
  NextItems = [Object || {Object, _Node, A} <- esubscribe:lookup(Name, update), A =/= self()],
  Items = [{IOA, Value} | NextItems],
  send_items([{IOA, Value} | Items], Connection, ?COT_SPONT, ASDUSettings),
  keep_state_and_data;

%% Handling call of remote control command
handle_event(
  {call, From},
  {write, IOA, Value},
  ?CONNECTED,
  Data
) ->
  % Start write request
  RC = #rc{
    state = confirm,
    type = maps:get(type, Value),
    from = From,
    ioa = IOA,
    value = Value
  },
  {next_state, RC, Data};

%% Event for the group update is received
%% Changing state to the group interrogation
handle_event(
  info,
  #gi{} = GI,
  ?CONNECTED,
  Data
) ->
  {next_state, GI, Data};

%%% +--------------------------------------------------------------+
%%% |                Sending remote control command                |
%%% +--------------------------------------------------------------+

%% Sending remote control command
handle_event(
  enter,
  _PrevState,
  #rc{state = confirm, type = Type, ioa = IOA, value = Value},
  #data{connection = Connection, asdu = ASDUSettings}
) ->
  [ASDU] = iec60870_asdu:build(#asdu{
    type = Type,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACT,
    objects = [{IOA, Value}]
  }, ASDUSettings),
  send_asdu(Connection, ASDU),
  {keep_state_and_data, [{state_timeout, ?CONFIRM_TIMEOUT, timeout}]};

%% Remote control command confirmation
handle_event(
  internal,
  #asdu{type = Type, cot = ?COT_ACTCON, pn = ?POSITIVE_PN, objects = [{IOA, _}]},
  #rc{state = confirm, ioa = IOA, type = Type} = State,
  Data
) ->
  {next_state, State#rc{state = run}, Data};

%% Remote control command rejected
handle_event(
  internal,
  #asdu{type = Type, cot = ?COT_ACTCON, pn = ?NEGATIVE_PN, objects = [{IOA, _}]},
  #rc{state = confirm, ioa = IOA, type = Type, from = From},
  Data
) ->
  {next_state, ?CONNECTED, Data, [{reply, From, {error, reject}}]};

handle_event(
  state_timeout,
  timeout,
  #rc{state = confirm, from = From},
  Data
) ->
  {next_state, ?CONNECTED, Data, [{reply, From, {error, confirm_timeout}}]};

%% Remote control command running
handle_event(
  enter,
  _PrevState,
  #rc{state = run},
  _Data
) ->
  {keep_state_and_data, [{state_timeout, ?RC_TIMEOUT, timeout}]};

%% Remote control command termination
handle_event(
  internal,
  #asdu{type = Type, cot = ?COT_ACTTERM, pn = ?POSITIVE_PN, objects = [{IOA, _}]},
  #rc{state = run, ioa = IOA, type = Type, from = From},
  Data
) ->
  {next_state, ?CONNECTED, Data, [{reply, From, ok}]};

% Not executed
handle_event(
  internal,
  #asdu{type = Type, cot = ?COT_ACTTERM, pn = ?NEGATIVE_PN, objects = [{IOA, _}]},
  #rc{state = run, ioa = IOA, type = Type, from = From},
  Data
) ->
  {next_state, ?CONNECTED, Data, [{reply, From, {error, not_executed}}]};

handle_event(
  state_timeout,
  timeout,
  #rc{state = run, from = From}, Data
) ->
  {next_state, ?CONNECTED, Data, [{reply, From, {error, execute_timeout}}]};

%%% +--------------------------------------------------------------+
%%% |                     Handling normal updates                  |
%%% +--------------------------------------------------------------+

handle_event(
  internal,
  #asdu{type = Type, objects = Objects, cot = COT} = ASDU,
  _AnyState,
  #data{name = Name, storage = Storage}
) when (Type >= ?M_SP_NA_1 andalso Type =< ?M_ME_ND_1)
    orelse (Type >= ?M_SP_TB_1 andalso Type =< ?M_EP_TD_1)
    orelse (Type =:= ?M_EI_NA_1) ->
  ?LOGDEBUG("client ~p: received normal update ASDU: ~p", [Name, ASDU]),
  Group =
    if
      COT >= ?COT_GROUP_MIN, COT =< ?COT_GROUP_MAX ->
        COT - ?COT_GROUP_MIN;
      true ->
        undefined
    end,
  [begin
     update_value(Name, Storage, IOA, Value#{type => Type, group => Group})
   end || {IOA, Value} <- Objects],
  keep_state_and_data;

%%% +--------------------------------------------------------------+
%%% |                  Time synchronization request                |
%%% +--------------------------------------------------------------+

handle_event(
  internal,
  #asdu{type = ?C_CS_NA_1, objects = Objects},
  _AnyState,
  #data{asdu = ASDUSettings, connection = Connection}
) ->
  [Confirmation] = iec60870_asdu:build(#asdu{
    type = ?C_CS_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_SPONT,
    objects = Objects
  }, ASDUSettings),
  send_asdu(Connection, Confirmation),
  keep_state_and_data;

%%% +--------------------------------------------------------------+
%%% |                        Unexpected ASDU                       |
%%% +--------------------------------------------------------------+

handle_event(
  internal,
  #asdu{type = ?C_IC_NA_1, cot = ?COT_ACTTERM, pn = PN, objects = [{_IOA, ID}]},
  _AnyState,
  #data{name = Name}
) ->
  ?LOGINFO("~p received termination of the group interrogation by ID: ~p, PN: ~p", [Name, ID, PN]),
  keep_state_and_data;

handle_event(
  internal,
  #asdu{} = Unexpected,
  State,
  #data{name = Name}
) ->
  ?LOGWARNING("~p unexpected ASDU type is received: ASDU ~p, state ~p", [
    Name,
    Unexpected,
    State
  ]),
  keep_state_and_data;

%%% +--------------------------------------------------------------+
%%% |                          Other events                        |
%%% +--------------------------------------------------------------+

%% Notify event from esubscribe, postpone until CONNECTED
handle_event(
  info,
  {write, _IOA, _Value},
  _State,
  _Data
) ->
  %% TODO. Can we send information packets during group interrogation?
  {keep_state_and_data, [postpone]};

handle_event(
  {call, _From},
  {write, _IOA, _Value},
  _State,
  _Data
) ->
  {keep_state_and_data, [postpone]};

% Group interrogation request, postpone until CONNECTED
handle_event(
  info,
  #gi{},
  _AnyState,
  _Data
) ->
  {keep_state_and_data, [postpone]};

%% Failed send errors received from client connection
handle_event(
  info,
  {send_error, Connection, Error},
  _AnyState,
  #data{connection = Connection}
) ->
  ?LOGWARNING("client connection failed to send packet, error: ~p", [Error]),
  keep_state_and_data;

%% The root process is down
handle_event(info, {'DOWN', _, process, Connection, Reason}, _AnyState, #data{
  name = Name,
  connection = Connection
}) ->
  ?LOGWARNING("~p client connection terminated. Reason: ~p", [Name, Reason]),
  {stop, Reason};

handle_event(
  EventType,
  EventContent,
  _AnyState,
  #data{name = Name}
) ->
  ?LOGWARNING("client connection ~p received unexpected event type ~p, content ~p", [
    Name, EventType, EventContent
  ]),
  keep_state_and_data.

terminate(Reason, _, _State = #data{esubscribe = PID})
  when Reason =:= normal; Reason =:= shutdown ->
    exit(PID, shutdown),
    ?LOGWARNING("client connection terminated with reason: ~p", [Reason]),
    ok;

terminate(Reason, _, _State) ->
  ?LOGWARNING("client connection terminated with reason: ~p", [Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% Sending data objects
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
  TypeAcc = maps:get(Type, Acc, #{}),
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
        % All object types have these keys
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