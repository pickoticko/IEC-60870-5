%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-module(iec60870_server_stm).
-behaviour(gen_statem).

-include("iec60870.hrl").
-include("asdu.hrl").

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

init( {Connection, #{name := Name, groups:=Groups} = Settings} ) ->
  esubscribe:subscribe(Name, update, self()),
  erlang:monitor(process, Connection),
  [begin
     timer:send_after(0, {update_group, GroupID, T})
   end || #{id := GroupID, update := T} <- Groups, is_integer(T)],
  {ok, ?RUNNING, #data{
    settings = Settings,
    connection = Connection
  }}.

handle_event(enter, _PrevState, ?RUNNING, _Data) ->
  keep_state_and_data;

% From esubscriber notify
handle_event(info, {Name, update, {IOA, Value}, _, Actor}, ?RUNNING, #data{
  settings = #{
    name := Name,
    asdu := ASDUSettings
  },
  connection = Connection
}) when Actor =/= self() ->
  %% Getting all updates
  Items = [Object || {Object, _Node, A} <- esubscribe:lookup(Name, update), A =/= self()],
  send_items([{IOA, Value} | Items], Connection, ?COT_SPONT, ASDUSettings),
  keep_state_and_data;

% From the connection
handle_event(info, {asdu, Connection, ASDU}, _AnyState, #data{
  settings = #{
    name := Name,
    asdu := ASDUSettings
  },
  connection = Connection
} = Data)->
  NewData =
    try
      ParsedASDU = iec60870_asdu:parse(ASDU, ASDUSettings),
      handle_asdu(ParsedASDU, Data)
    catch
      _:E ->
        ?LOGERROR("~p invalid ASDU received: ~p, error: ~p", [Name, ASDU, E]),
        Data
    end,
  {keep_state, NewData};

% Ignore self notifications
handle_event(info, {_Scope, update, _, _, _Self}, _AnyState, _Data) ->
  keep_state_and_data;

handle_event(info, {update_group, GroupID, Timer}, ?RUNNING, #data{
  settings = #{
    root := Root,
    asdu := ASDUSettings
  },
  connection = Connection
}) ->
  timer:send_after( Timer, {update_group, GroupID, Timer} ),
  Items = iec60870_server:find_group_items(Root, GroupID),
  send_items(Items, Connection, ?COT_PER, ASDUSettings),
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

handle_asdu(#asdu{
  type = ?C_IC_NA_1,
  objects = [{IOA, GroupID}]
}, #data{
  settings = #{
    asdu := ASDUSettings,
    root := Root
  },
  connection = Connection
} = Data) ->
  %% ----- Send initialization -----
  [Confirmation] = iec60870_asdu:build(#asdu{
    type = ?C_IC_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_SPONT,
    objects = [{IOA, GroupID}]
  }, ASDUSettings),
  send_asdu(Connection, Confirmation),

  %% ----- Sending items -----
  Items = iec60870_server:find_group_items(Root, GroupID),
  send_items(Items, Connection, ?COT_GROUP(GroupID), ASDUSettings),

  %% ----- Send termination -----
  [Termination] = iec60870_asdu:build(#asdu{
    type = ?C_IC_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACTTERM,
    objects = [{IOA, GroupID}]
  }, ASDUSettings),
  send_asdu(Connection, Termination),
  Data;

handle_asdu(#asdu{
  type = ?C_CI_NA_1,
  objects = [{IOA, GroupID}]
}, #data{
  settings = #{
    asdu := ASDUSettings
  },
  connection = Connection
} = Data) ->
  %% ----- Send initialization -----
  [Confirmation] = iec60870_asdu:build(#asdu{
    type = ?C_CI_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_SPONT,
    objects = [{IOA, GroupID}]
  }, ASDUSettings),
  send_asdu(Connection, Confirmation),
  %% --------------------------------------------
  %% TODO: Counter interrogation is not supported
  %% ----- Send termination ---------------------
  [Termination] = iec60870_asdu:build(#asdu{
    type = ?C_CI_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACTTERM,
    objects = [{IOA, GroupID}]
  }, ASDUSettings),
  send_asdu(Connection, Termination),
  Data;

handle_asdu(#asdu{
  type = ?C_CS_NA_1,
  objects = Objects
}, #data{
  settings = #{
    asdu := ASDUSettings
  },
  connection = Connection
} = Data) ->
  %% ----- Send initialization -----
  [Confirmation] = iec60870_asdu:build(#asdu{
    type = ?C_CS_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_SPONT,
    objects = Objects
  }, ASDUSettings),
  send_asdu(Connection, Confirmation),
  Data;

handle_asdu(#asdu{
  type = Type,
  objects = Objects
}, #data{
  settings = #{
    root := Root
  }
} = Data) when Type >= ?M_SP_NA_1, Type =< ?M_EP_TF_1 ->
  [iec60870_server:update_value(Root, IOA, Value) || {IOA, Value} <- Objects],
  Data;

handle_asdu(#asdu{
  type = Type
}, #data{
  settings = #{name := Name}
} = Data) ->
  ?LOGWARNING("~p unsupported ASDU type is received: ~p", [Name, Type]),
  Data.

send_asdu(Connection, ASDU) ->
  Connection ! {asdu, self(), ASDU}, ok.

group_by_types(Objects) ->
  group_by_types(Objects, #{}).
group_by_types([{IOA, #{type := Type} =Value }|Rest], Acc) ->
  TypeAcc = maps:get(Type,Acc,#{}),
  Acc1 = Acc#{Type => TypeAcc#{IOA => Value}},
  group_by_types(Rest, Acc1);
group_by_types([], Acc) ->
  [{Type, lists:sort(maps:to_list(Objects))} || {Type, Objects} <- maps:to_list(Acc)].

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