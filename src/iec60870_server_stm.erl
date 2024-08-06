%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_server_stm).
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
  root,
  groups,
  settings,
  connection
}).

%% States
-define(RUNNING, running).

-define(ESUBSCRIBE_DELAY, 100).

%%% +--------------------------------------------------------------+
%%% |                  OTP behaviour implementation                |
%%% +--------------------------------------------------------------+

callback_mode() -> [
  handle_event_function,
  state_enter
].

init({Root, Connection, #{name := Name, groups := Groups} = Settings}) ->
  ?LOGINFO("server ~p: initiating incoming connection...", [Name]),
  esubscribe:subscribe(Name, update, self()),
  process_flag(trap_exit, true),
  erlang:monitor(process, Root),
  init_group_requests(Groups),
  {ok, ?RUNNING, #data{
    root = Root,
    settings = Settings,
    connection = Connection
  }}.

handle_event(enter, _PrevState, ?RUNNING, _Data) ->
  keep_state_and_data;

handle_event(info, {Name, update, {IOA, DataObject}, _, Actor}, ?RUNNING, #data{
  settings = #{
    name := Name
  }
} = Data) when Actor =/= self() ->
  % Getting all updates
  Items = [Object ||
    {Object, _Node, A} <- esubscribe:wait(Name, update, ?ESUBSCRIBE_DELAY), A =/= self()],
  send_items([{IOA, DataObject} | Items], ?COT_SPONT, Data),
  keep_state_and_data;

%% From the connection
handle_event(info, {asdu, Connection, ASDU}, _AnyState, #data{
  settings = #{
    name := Name,
    asdu := ASDUSettings
  },
  connection = Connection
} = Data)->
  try
    ParsedASDU = iec60870_asdu:parse(ASDU, ASDUSettings),
    check_duplicates(ParsedASDU, ASDU),
    handle_asdu(ParsedASDU, Data)
  catch
    _Exception:Error ->
      ?LOGERROR("~p server received invalid ASDU. ASDU: ~p, Error: ~p", [Name, ASDU, Error]),
      keep_state_and_data
  end;

%% Ignore self notifications
handle_event(info, {_Scope, update, _, _, _Self}, _AnyState, _Data) ->
  keep_state_and_data;

handle_event(info, {update_group, GroupID, Timer}, ?RUNNING, #data{
  settings = #{
    root := Root
  }
} = Data) ->
  timer:send_after(Timer, {update_group, GroupID, Timer}),
  Items = iec60870_server:find_group_items(Root, GroupID),
  send_items(Items, ?COT_PER, Data),
  keep_state_and_data;

%% The connection is down
handle_event(info, {'EXIT', Connection, Reason}, _AnyState, #data{
  connection = Connection
}) ->
  ?LOGWARNING("server connection terminated. Reason: ~p", [Reason] ),
  {stop, Reason};

%% The root process is down
handle_event(info, {'DOWN', _, process, Root, Reason}, _AnyState, #data{
  root = Root
}) ->
  ?LOGWARNING("incoming server connection terminated. Reason: ~p", [Reason]),
  {stop, Reason};

handle_event(EventType, EventContent, _AnyState, _Data) ->
  ?LOGWARNING("incoming server connection received unexpected event type. Event: ~p, Content: ~p", [
    EventType, EventContent
  ]),
  keep_state_and_data.

terminate(Reason, _, _State) when Reason =:= normal; Reason =:= shutdown ->
  ?LOGWARNING("incoming server connection is terminated normally. Reason: ~p", [Reason]),
  ok;
terminate({connection_closed, Reason}, _, _State)->
  ?LOGWARNING("incoming server connection is closed. Reason: ~p", [Reason]),
  ok;
terminate(Reason, _, _Data) ->
  ?LOGWARNING("incoming server connection is terminated abnormally. Reason: ~p", [Reason]),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init_group_requests(Groups)  ->
  [begin
     timer:send_after(0, {update_group, GroupID, Millis})
   end || #{id := GroupID, update := Millis} <- Groups, is_integer(Millis)].

%% Receiving information data objects
handle_asdu(#asdu{
  type = Type,
  objects = Objects
}, #data{
  settings = #{
    command_handler := Handler,
    root := Root
  }
})
  when (Type >= ?M_SP_NA_1 andalso Type =< ?M_ME_ND_1)
    orelse (Type >= ?M_SP_TB_1 andalso Type =< ?M_EP_TD_1)
    orelse (Type =:= ?M_EI_NA_1) ->
  % When a command handler is defined, any information data objects should be ignored
  case is_function(Handler) of
    true ->
      ignore;
    false ->
      [iec60870_server:update_value(Root, IOA, Value) || {IOA, Value} <- Objects]
  end,
  keep_state_and_data;

%% Remote control commands
%% +--------------------------------------------------------------+
%% | Note: The write request on the server begins with the        |
%% | execution of the handler. It is asynchronous because we      |
%% | don't want to delay the work of the entire state machine.    |
%% | Handler must return {error, Error} or ok                     |
%% +--------------------------------------------------------------+

handle_asdu(#asdu{
  type = Type,
  objects = Objects
}, #data{
  settings = #{
    command_handler := Handler,
    asdu := ASDUSettings,
    root := ServerRef
  }
} = Data)
  when (Type >= ?C_SC_NA_1 andalso Type =< ?C_BO_NA_1)
    orelse (Type >= ?C_SC_TA_1 andalso Type =< ?C_BO_TA_1) ->
  if
    is_function(Handler) ->
      try
        [{IOA, Value}] = Objects,
        case Handler(ServerRef, Type, IOA, Value) of
          {error, HandlerError} ->
            ?LOGERROR("remote control handler returned error: ~p", [HandlerError]),
            %% +-------[ Negative activation confirmation ]---------+
            NegativeConfirmation = build_asdu(Type, ?COT_ACTCON, ?NEGATIVE_PN, Objects, ASDUSettings),
            send_asdu(NegativeConfirmation, Data);
          ok ->
            %% +------------[ Activation confirmation ]-------------+
            Confirmation = build_asdu(Type, ?COT_ACTCON, ?POSITIVE_PN, Objects, ASDUSettings),
            send_asdu(Confirmation, Data),
            %% +------------[ Activation termination ]--------------+
            Termination = build_asdu(Type, ?COT_ACTTERM, ?POSITIVE_PN, Objects, ASDUSettings),
            send_asdu(Termination, Data)
        end
      catch
        _Exception:Reason ->
          ?LOGERROR("remote control handler failed. Reason: ~p", [Reason]),
          %% +-------[ Negative activation confirmation ]---------+
          ExceptionConfirmation = build_asdu(Type, ?COT_ACTCON, ?NEGATIVE_PN, Objects, ASDUSettings),
          send_asdu(ExceptionConfirmation, Data)
      end;
    true ->
      %% +-------[ Negative activation confirmation ]---------+
      ?LOGWARNING("remote control request accepted but no handler is defined"),
      NegativeConfirmation = build_asdu(Type, ?COT_ACTCON, ?NEGATIVE_PN, Objects, ASDUSettings),
      send_asdu(NegativeConfirmation, Data)
  end,
  keep_state_and_data;

%% General Interrogation Command
handle_asdu(#asdu{
  type = ?C_IC_NA_1,
  objects = [{IOA, GroupID}]
}, #data{
  settings = #{
    asdu := ASDUSettings,
    root := Root,
    name := Name
  }
} = Data) ->
  ?LOGDEBUG("server ~p: received GI to group ~p", [Name, GroupID]),
  % +-------------[ Send initialization ]-------------+
  [Confirmation] = iec60870_asdu:build(#asdu{
    type = ?C_IC_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACTCON,
    objects = [{IOA, GroupID}]
  }, ASDUSettings),
  send_asdu(Confirmation, Data),
  % +----------------[ Sending items ]----------------+
  Items = iec60870_server:find_group_items(Root, GroupID),
  send_items(Items, ?COT_GROUP(GroupID), Data),
  % +---------------[ Send termination ]--------------+
  [Termination] = iec60870_asdu:build(#asdu{
    type = ?C_IC_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACTTERM,
    objects = [{IOA, GroupID}]
  }, ASDUSettings),
  send_asdu(Termination, Data),
  keep_state_and_data;

%% Counter Interrogation Command
handle_asdu(#asdu{
  type = ?C_CI_NA_1,
  objects = [{IOA, GroupID}]
}, #data{
  settings = #{
    asdu := ASDUSettings
  }
} = Data) ->
  % +-------------[ Send initialization ]-------------+
  [Confirmation] = iec60870_asdu:build(#asdu{
    type = ?C_CI_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACTCON,
    objects = [{IOA, GroupID}]
  }, ASDUSettings),
  send_asdu(Confirmation, Data),
  % --------------------------------------------
  % TODO: Counter interrogation is not supported
  % +---------------[ Send termination ]--------------+
  [Termination] = iec60870_asdu:build(#asdu{
    type = ?C_CI_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACTTERM,
    objects = [{IOA, GroupID}]
  }, ASDUSettings),
  send_asdu(Termination, Data),
  keep_state_and_data;

%% Clock Synchronization Command
handle_asdu(#asdu{
  type = ?C_CS_NA_1,
  objects = Objects
}, #data{
  settings = #{
    asdu := ASDUSettings
  }
} = Data) ->
  % +-------------[ Send initialization ]-------------+
  [Confirmation] = iec60870_asdu:build(#asdu{
    type = ?C_CS_NA_1,
    pn = ?POSITIVE_PN,
    cot = ?COT_ACTCON,
    objects = Objects
  }, ASDUSettings),
  send_asdu(Confirmation, Data),
  keep_state_and_data;

%% All other unexpected asdu types
handle_asdu(#asdu{
  type = Type
}, #data{
  settings = #{name := Name}
}) ->
  ?LOGWARNING("~p server received unsupported ASDU type. Type: ~p", [Name, Type]),
  keep_state_and_data.

check_duplicates(#asdu{type = Type}, _BinaryPacket)
  when Type >= ?C_SC_NA_1 andalso ?C_BO_TA_1 =< Type ->
    ok;
check_duplicates(_ASDU, BinaryPacket) ->
  drop_duplicates(BinaryPacket).

drop_duplicates(BinaryPacket) ->
  receive
    {asdu, _Connection, BinaryPacket} -> drop_duplicates(BinaryPacket)
  after
    0 -> ok
  end.

send_items(Items, COT, #data{
  settings = #{
    asdu := ASDUSettings,
    name := Name
  }
} = Data) ->
  ByTypes = group_by_types(Items),
  [begin
     ListASDU = iec60870_asdu:build(#asdu{
       type = Type,
       pn = ?POSITIVE_PN,
       cot = COT,
       objects = Objects
     }, ASDUSettings),
     ?LOGDEBUG("server ~p: sending packets: ~p", [Name, ListASDU]),
     [send_asdu(ASDU, Data) || ASDU <- ListASDU]
   end || {Type, Objects} <- ByTypes].

group_by_types(Objects) ->
  group_by_types(Objects, #{}).
group_by_types([{IOA, #{type := Type} = Value} | Rest], Acc) ->
  TypeAcc = maps:get(Type, Acc, #{}),
  Acc1 = Acc#{Type => TypeAcc#{IOA => Value}},
  group_by_types(Rest, Acc1);
group_by_types([], Acc) ->
  [{Type, lists:sort(maps:to_list(Objects))} || {Type, Objects} <- maps:to_list(Acc)].

build_asdu(Type, COT, PN, Objects, Settings) ->
  [Packet] = iec60870_asdu:build(#asdu{
    type = Type,
    cot = COT,
    pn = PN,
    objects = Objects
  }, Settings),
  Packet.

send_asdu(ASDU, #data{
  connection = Connection
} = Data) ->
  Reference = make_ref(),
  Connection ! {asdu, self(), Reference, ASDU},
  wait_confirmation(Reference, _Updates = #{}, Data).

%% Waiting confirmation by unique reference from the connection
wait_confirmation(Reference, Updates, #data{
  connection = Connection,
  root = Root,
  settings = #{
    name := Name
  }
} = Data) ->
  receive
    {'EXIT', Connection, Reason} ->
      exit(Reason);
    {'DOWN', _, process, Root, Reason} ->
      exit(Reason);
    {Name, update, {IOA, DataObject}, _, Actor} when Actor =/= self() ->
      wait_confirmation(Reference, Updates#{IOA => DataObject}, Data);
    {_, update, _, _, _} ->
      wait_confirmation(Reference, Updates, Data);
    {confirm, Reference} ->
      if
        map_size(Updates) > 0 ->
          send_delayed_updates(Updates, Data);
        true ->
          ignore
      end,
      ok
  end.

send_delayed_updates(Updates, #data{
  settings = #{
    name := Name
  }
} = Data) ->
  receive
    {Name, update, {IOA, DataObject}, _, Actor} when Actor =/= self() ->
      send_delayed_updates(Updates#{IOA => DataObject}, Data)
  after
    0 ->
      ?LOGDEBUG("server ~p: send delayed updates"),
      maps:foreach(
        fun(Key, Value) ->
          self() ! {Name, update, {Key, Value}, none, none}
        end, Updates),
      ok
  end.