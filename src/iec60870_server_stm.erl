%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-module(iec60870_server_stm).
-behaviour(gen_statem).

-include("iec60870.hrl").

-export([
  start_link/1
]).

-export([
  callback_mode/0,
  code_change/3,
  init/1,
  handle_event/4,
  terminate/3
]).


-record(data, {
  cache,
  groups,
  settings,
  connection
}).

%% +--------------------------------------------------------------+
%% |                           States                             |
%% +--------------------------------------------------------------+
-define(RUNNING, running).

%% +--------------------------------------------------------------+
%% |                   OTP gen_statem behaviour                   |
%% +--------------------------------------------------------------+

callback_mode() -> [
  handle_event_function,
  state_enter
].

start_link( Options )->
  case gen_statem:start_link(?MODULE, {_Connection = self(), Options}, []) of
    {ok, PID} -> PID;
    {error, Error} -> throw(Error)
  end.

init( {Connection, Settings} ) ->

  erlang:monitor(process, Connection),

  {ok, ?RUNNING, #data{
    cache = maps:get( cache, Settings ),
    settings = Settings,
    connection = Connection
  }}.

% --------------------------------------------

handle_event(enter, _PrevState, ?RUNNING, _Data) ->
  keep_state_and_data;

% From esubscriber notify
handle_event(info, {Scope, update, {IOA, Value}, _Node, Actor}, ?RUNNING, #data{
  settings = #{name := Scope},
  connection = Connection
}) when Actor =/= self() ->

  Items = get_all_updates( Scope ),
  ByTypes = group_by_types( Items ),

  [ begin
      ASDU = build_asdu( Type, ?COT_SPONT, TypeUpdates ),
      send_asdu( Connection, ASDU )
   end || {Type, TypeUpdates} <- maps:to_list( ByTypes )],

  %iec60870_connection:cmd(Connection, {write_object, IOA, Value, spontaneous}),
  keep_state_and_data;

% Group request {object, Type, ValueCOT, Address, Value}
handle_event(info, ?DATA(Connection, ?OBJECT(?C_IC_NA_1, ?COT_ACT, _IOA, GroupID)), ?RUNNING, #data{
  connection = Connection,
  cache = Cache
}) ->

  Confirm = build_asdu( ?C_IC_NA_1, ?COT_ACTCON, [{_IOA = 0, GroupID}] ),
  %iec60870_connection:cmd(Connection, {group_request_confirm, GroupID}),

  Items = find_group_items( GroupID, Cache ),

  ByTypes = group_by_types( Items ),

  [ begin
      ASDU = build_asdu( Type, ?COT_GROUP( GroupID ), TypeUpdates ),
      send_asdu( Connection, ASDU )
    end || {Type, TypeUpdates} <- maps:to_list( ByTypes )],

  %[ iec60870_connection:cmd(Connection, {write_object, IOA, Value, {group, GroupID}}) || { IOA, Value } <- Items ],

  Confirm = build_asdu( ?C_IC_NA_1, ?COT_ACTTERM, [{_IOA = 0, GroupID}] ),
  %iec60870_connection:cmd(Connection, {group_request_terminate, GroupID}),

  keep_state_and_data;

% From the connection
handle_event(info, {asdu, Connection, ASDU}, ?RUNNING, #data{
  settings = #{name := Name},
  connection = Connection,
  cache = Cache
} = Data)->

  case parse_asdu( ASDU ) of
    {ok, {Type, TypeData} }->
      handle_type( Type, TypeData, Data );
    {error, Error} ->
      ?LOGERROR("invalid ASDU received: ~p",[ASDU])
  end,

  keep_state_and_data;

% Ignore self notifications
handle_event(info, {_Scope, update, _, _, _Self}, _AnyState, _Data) ->
  keep_state_and_data;

% The server is down
handle_event(info, {'DOWN', _, process, Connection, Error}, _AnyState, #data{
  connection = Connection
}) ->
  ?LOGINFO("stop incoming connection, reason: ~p", [Error] ),
  {stop, Error};

% Log unexpected events
handle_event(EventType, EventContent, _AnyState, _Data) ->
  ?LOGWARNING("Server connection received unexpected event type ~p, content ~p", [
    EventType, EventContent
  ]),
  keep_state_and_data.

terminate(Reason, _, _State) when Reason=:=normal; Reason =:= shutdown->
  ?LOGDEBUG("incoming connection is terminated. Reason: ~p", [Reason]),
  ok;
terminate({connection_closed,Reason}, _, _State)->
  ?LOGDEBUG("incoming connection is closed. Reason: ~p", [Reason]),
  ok;
terminate(Reason, _, _Data) ->
  ?LOGWARNING("incoming connection is terminated. Reason: ~p", [Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% +--------------------------------------------------------------+
%% |             Internal helpers                                 |
%% +--------------------------------------------------------------+
handle_asdu( #asdu{}  )->
  todo.

update_value(Scope, Cache, Type, IOA, InValue) when is_map( InValue )->

  Group =
    case InValue of
      #{ group := _G } when is_number( _G )-> _G;
      _->
        case ets:lookup( Cache, IOA ) of
          [{_, #{ group :=_G }}] -> _G;
          _-> undefined
        end
    end,

  Value = maps:merge(#{
    group => Group,
    type => Type,
    value => undefined,
    ts => erlang:system_time(millisecond),
    qds => undefined
  }, InValue),

  ets:insert(Cache, {IOA, Value}),
  % Any updates notification
  esubscribe:notify(Scope, update, {IOA, Value}),
  % Only address notification
  esubscribe:notify(Scope, IOA, Value);

update_value(_Scope, _Cache, Type, IOA, InValue)->
  % TODO. We should handle this types in state machine states
  ?LOGWARNING("unexpected type message: type ~p, IOA ~p, Value ~p",[
    Type,
    IOA,
    InValue
  ]).

find_group_items( _GroupID = 0, Cache )->
  ets:tab2list( Cache );
find_group_items( GroupID, Cache )->
  ets:match_object(Cache, {'_',#{ group => GroupID }}).

send_asdu( Connection, ASDU )->
  Connection ! {asdu, self(), ASDU},
  ok.

