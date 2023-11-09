%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+

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
  type:=Type,
  connection := ConnectionSettings,
  groups := Groups
} = Settings}) ->

  Storage = ets:new(data_objects, [
    set,
    public,
    {read_concurrency, true},
    {write_concurrency, auto}
  ]),

  ASDU = iec60870_asdu:get_settings( maps:with(maps:keys(?DEFAULT_ASDU_SETTINGS), Settings)),

  case esubscribe:start_link( Name ) of
    {ok, _PID} -> ok;
    {error, Reason} -> throw(Reason)
  end,


  {ok, {?CONNECTING, Type, ConnectionSettings}, #data{
    owner = Owner,
    name = Name,
    storage = Storage,
    asdu = ASDU,
    groups = Groups
  }}.

%% +--------------------------------------------------------------+
%% |                      Connecting State                        |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState,{ ?CONNECTING, _, _}, _Data) ->
  {keep_state_and_data, [{state_timeout, 0, connect}]};

handle_event(state_timeout, connect, {?CONNECTING, Type, Settings}, #data{
  groups = Groups
} =Data)->

  Module = iec60870_lib:get_driver_module( Type ),

  Connection = Module:start_client( Settings ),

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

  % TODO. handle group versions
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
      #{ GroupID := #{ timeout := Timeout } } when is_integer( Timeout )->
        [{state_timeout, Timeout, timeout}];
      _->
        []
    end,

  {keep_state_and_data, Actions};


handle_event(state_timeout, timeout, {?GROUP_REQUEST, update, #{id := ID}, _NextState}, _Data) ->
  {stop, {group_request_timeout, ID}};

%% +--------------------------------------------------------------+
%% |                          Connected                           |
%% +--------------------------------------------------------------+

handle_event(enter, _PrevState, ?CONNECTED, _Data) ->
  keep_state_and_data;

handle_event(info, {update_group, Group, PID}, ?CONNECTED, Data) when PID =:= self() ->
  {next_state, {?GROUP_REQUEST, init, Group, ?CONNECTED}, Data};


%% +--------------------------------------------------------------+
%% |                        Update event                          |
%% +--------------------------------------------------------------+

% From esubscriber notify
handle_event(info, {write, IOA, Value}, _State, #data{
  name = Name,
  connection = Connection,
  asdu = ASDUSettings,
  storage = Storage
}) ->

  %% Getting all updates
  NextItems = [Object || {Object, _Node, A} <- esubscribe:lookup(Name, update), A =/= self()],
  Items = [{IOA, Value} | NextItems],

  send_items([{IOA, Value} | Items], Connection, ?COT_SPONT, ASDUSettings),

  [update_value(Name, Storage, ID, V) || {ID, V} <- Items],

  keep_state_and_data;


handle_event(info, {asdu, Connection, ASDU}, State, #data{
  name = Name,
  connection = Connection,
  asdu = ASDUSettings
} = Data)->
  try
    ParsedASDU = iec60870_asdu:parse(ASDU, ASDUSettings),
    handle_asdu(ParsedASDU, State, Data)
  catch
    _:E ->
      ?LOGERROR("~p invalid ASDU received: ~p, error: ~p", [Name, ASDU, E]),
      keep_state_and_data
  end;

%% Log unexpected events
handle_event(EventType, EventContent, _AnyState, #data{ name = Name}) ->
  ?LOGWARNING("Client connection ~p received unexpected event type ~p, content ~p", [
    Name, EventType, EventContent
  ]),
  keep_state_and_data.

terminate(Reason, _, _State) when Reason=:=normal; Reason =:= shutdown->
  ?LOGDEBUG("client connection terminated. Reason: ~p", [Reason]),
  ok;
terminate(Reason, _, _ClientState) ->
  ?LOGWARNING("client connection terminated. Reason: ~p", [Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.


%-------------------Data updates----------------------------
handle_asdu(#asdu{
  type = Type,
  objects = Objects,
  cot = COT
}, _State, #data{
  name = Name,
  storage = Storage
}) when Type >= ?M_SP_NA_1, Type =< ?M_EP_TF_1 ->

  Group =
    if
      COT >= ?COT_GROUP_MIN, COT =< ?COT_GROUP_MAX-> COT - ?COT_GROUP_MIN;
      true -> undefined
    end,

  [update_value(Name, Storage, IOA, Value#{type => Type, group => Group }) || {IOA, Value} <- Objects],

  keep_state_and_data;

%-------------------Confirmation fo group request----------------------------
handle_asdu(#asdu{
  type = ?C_IC_NA_1,
  cot = ?COT_ACTCON,
  objects = [{_IOA, GroupID}]
}, {?GROUP_REQUEST, init, #{id := GroupID} = Group, NextState}, Data) ->

  Actions =
    case Group of
      #{ timeout := Timeout } when is_integer( Timeout )->
        [{state_timeout, Timeout, timeout}];
      _->
        []
    end,

  {next_state, {?GROUP_REQUEST, update, Group, NextState}, Data, Actions};

%-------------------Termination fo group request----------------------------
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

%-------------------Time synchronization request----------------------------
handle_asdu(#asdu{ type = ?C_CS_NA_1, objects = Objects}, _State, #data{
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


handle_asdu(#asdu{}=Unexpected, State, #data{name = Name}) ->
  ?LOGWARNING("~p unexpected ASDU type is received: ASDU ~p, state ~p", [Name, Unexpected, State]),
  keep_state_and_data.


send_items(Items, Connection, COT, ASDUSettings) ->
  ByTypes = group_by_types(Items),
  [begin
     ListASDU = iec60870_asdu:build(#asdu{
       type = Type,
       pn = ?POSITIVE_PN,
       cot = COT,
       objects = Objects
     }, ASDUSettings),
     [send_asdu(Connection, ASDU) || ASDU <- ListASDU]
   end || {Type, Objects} <- ByTypes].

group_by_types(Objects) ->
  group_by_types(Objects, #{}).
group_by_types([{IOA, #{type := Type} =Value }|Rest], Acc) ->
  TypeAcc = maps:get(Type,Acc,#{}),
  Acc1 = Acc#{Type => TypeAcc#{IOA => Value}},
  group_by_types(Rest, Acc1);
group_by_types([], Acc) ->
  [{Type, lists:sort(maps:to_list(Objects))} || {Type, Objects} <- maps:to_list(Acc)].

send_asdu(Connection, ASDU) ->
  Connection ! {asdu, self(), ASDU}, ok.


update_value(Name, Storage, ID, InValue)->
  Group =
    case InValue of
      #{ group := _G } when is_number( _G )-> _G;
      _->
        case ets:lookup( Storage, ID ) of
          [{_, #{ group :=_G }}] -> _G;
          _-> undefined
        end
    end,

  Value = maps:merge(#{
    group => Group,
    type => undefined,
    value => undefined,
    ts => undefined,
    accept_ts => erlang:system_time(millisecond),
    qds => undefined
  }, InValue),

  ets:insert(Storage, {ID, Value}),
  % Any updates notification
  esubscribe:notify(Name, update, {ID, Value}),
  % Only address notification
  esubscribe:notify(Name, ID, Value).