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
%%% |                     Server Process Tree                      |
%%% +--------------------------------------------------------------+
%%% |                  Server State Machine                        |
%%% |                      /          \                            |
%%% |           Update Queue          Send Queue                   |
%%% |                                          \                   |
%%% |                                          Connection          |
%%% +--------------------------------------------------------------+
%%% | Description:                                                 |
%%% |   - Server STM: handles events and acts as an orchestrator   |
%%% |      of the other processes in the tree                      |
%%% |   - Update queue: receives updates from esubscribe and       |
%%% |      handles group requests                                  |
%%% |   - Send queue: receives command functions from STM and      |
%%% |     updates from update queue to send to the connection      |
%%% |   - Connection: handles transport level communication        |
%%% | All processes are linked according to the tree               |
%%% +--------------------------------------------------------------+

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

-record(state, {
  root,
  groups,
  settings,
  connection,
  send_queue,
  update_queue
}).

-record(update_state, {
  owner,
  name,
  tickets,
  update_queue,
  send_queue_pid,
  asdu_settings,
  storage
}).

-record(send_state, {
  owner,
  name,
  update_queue_pid,
  send_queue,
  connection
}).

-define(REMOTE_CONTROL_PRIORITY, 0).
-define(COMMAND_PRIORITY, 1).
-define(UPDATE_PRIORITY, 2).

-define(GLOBAL_GROUP, 0).
-define(START_GROUP, 1).
-define(END_GROUP, 16).

-define(ESUBSCRIBE_DELAY, 100).

%% States
-define(RUNNING, running).

%%% +--------------------------------------------------------------+
%%% |                  OTP behaviour implementation                |
%%% +--------------------------------------------------------------+

callback_mode() -> [
  handle_event_function,
  state_enter
].

init({Root, Connection, #{
  name := Name,
  groups := Groups,
  storage := Storage
} = Settings}) ->
  ?LOGINFO("server ~p: initiating incoming connection...", [Name]),
  SendQueue = init_send_queue(Name, Connection),
  UpdateQueue = init_update_queue(Name, Storage, SendQueue),
  SendQueue ! {ok, self(), UpdateQueue},
  process_flag(trap_exit, true),
  erlang:monitor(process, Root),
  init_group_requests(Groups),
  {ok, ?RUNNING, #state{
    root = Root,
    settings = Settings,
    connection = Connection,
    send_queue = SendQueue,
    update_queue = UpdateQueue
  }}.

handle_event(enter, _PrevState, ?RUNNING, _Data) ->
  keep_state_and_data;

%% Incoming packets from the connection
handle_event(info, {asdu, Connection, ASDU}, _AnyState, #state{
  settings = #{
    name := Name,
    asdu := ASDUSettings
  },
  connection = Connection
} = State)->
  try
    ParsedASDU = iec60870_asdu:parse(ASDU, ASDUSettings),
    handle_asdu(ParsedASDU, State)
  catch
    _Exception:Error ->
      ?LOGERROR("~p server received invalid ASDU. ASDU: ~p, Error: ~p", [Name, ASDU, Error]),
      keep_state_and_data
  end;

handle_event(info, {update_group, GroupID, Timer}, ?RUNNING, #state{
  update_queue = UpdateQueue
}) ->
  UpdateQueue ! {general_interrogation, self(), {update_group, GroupID}},
  timer:send_after(Timer, {update_group, GroupID, Timer}),
  keep_state_and_data;

%% The connection is down
handle_event(info, {'EXIT', Connection, Reason}, _AnyState, #state{
  connection = Connection
}) ->
  ?LOGWARNING("server connection terminated. Reason: ~p", [Reason]),
  {stop, Reason};

%% The send queue process is down
handle_event(info, {'EXIT', SendQueue, Reason}, _AnyState, #state{
  send_queue = SendQueue
}) ->
  ?LOGWARNING("server send queue process terminated. Reason: ~p", [Reason]),
  {stop, Reason};

%% The update queue process is down
handle_event(info, {'EXIT', UpdateQueue, Reason}, _AnyState, #state{
  send_queue = UpdateQueue
}) ->
  ?LOGWARNING("server update queue process terminated. Reason: ~p", [Reason]),
  {stop, Reason};

%% The root process is down
handle_event(info, {'DOWN', _, process, Root, Reason}, _AnyState, #state{
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
}, #state{
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
}, #state{
  settings = #{
    command_handler := Handler,
    asdu := ASDUSettings,
    root := ServerRef
  }
} = State)
  when (Type >= ?C_SC_NA_1 andalso Type =< ?C_BO_NA_1)
    orelse (Type >= ?C_SC_TA_1 andalso Type =< ?C_BO_TA_1) ->
  if
    is_function(Handler) ->
      try
        [{IOA, Value}] = Objects,
        case Handler(ServerRef, Type, IOA, Value) of
          {error, HandlerError} ->
            ?LOGERROR("remote control handler returned error: ~p", [HandlerError]),
            NegativeConfirmation = build_asdu(Type, ?COT_ACTCON, ?NEGATIVE_PN, Objects, ASDUSettings),
            send_asdu(?COMMAND_PRIORITY, NegativeConfirmation, State);
          ok ->
            %% +------------[ Activation confirmation ]-------------+
            Confirmation = build_asdu(Type, ?COT_ACTCON, ?POSITIVE_PN, Objects, ASDUSettings),
            send_asdu(?COMMAND_PRIORITY, Confirmation, State),
            %% +------------[ Activation termination ]--------------+
            Termination = build_asdu(Type, ?COT_ACTTERM, ?POSITIVE_PN, Objects, ASDUSettings),
            send_asdu(?COMMAND_PRIORITY, Termination, State)
        end
      catch
        _Exception:Reason ->
          ?LOGERROR("remote control handler failed. Reason: ~p", [Reason]),
          %% +-------[ Negative activation confirmation ]---------+
          ExceptionNegConfirmation = build_asdu(Type, ?COT_ACTCON, ?NEGATIVE_PN, Objects, ASDUSettings),
          send_asdu(?COMMAND_PRIORITY, ExceptionNegConfirmation, State)
      end;
    true ->
      %% +-------[ Negative activation confirmation ]---------+
      ?LOGWARNING("remote control request accepted but no handler is defined"),
      NegativeConfirmation = build_asdu(Type, ?COT_ACTCON, ?NEGATIVE_PN, Objects, ASDUSettings),
      send_asdu(?COMMAND_PRIORITY, NegativeConfirmation, State)
  end,
  keep_state_and_data;

%% General Interrogation Command
handle_asdu(#asdu{
  type = ?C_IC_NA_1,
  objects = [{_IOA, GroupID}]
}, #state{
  update_queue = UpdateQueue,
  settings = #{
    name := Name
  }
}) ->
  ?LOGDEBUG("server ~p: received GI to group ~p", [Name, GroupID]),
  UpdateQueue ! {general_interrogation, self(), GroupID},
  keep_state_and_data;

%% Counter Interrogation Command
handle_asdu(#asdu{
  type = ?C_CI_NA_1,
  objects = [{IOA, GroupID}]
}, #state{
  settings = #{
    asdu := ASDUSettings
  }
} = State) ->
  % TODO: Counter Interrogation is not supported
  [NegativeConfirmation] = iec60870_asdu:build(#asdu{
    type = ?C_CI_NA_1,
    pn = ?NEGATIVE_PN,
    cot = ?COT_ACTCON,
    objects = [{IOA, GroupID}]
  }, ASDUSettings),
  send_asdu(?COMMAND_PRIORITY, NegativeConfirmation, State),
  keep_state_and_data;

%% Clock Synchronization Command
handle_asdu(#asdu{
  type = ?C_CS_NA_1
}, #state{}) ->
  % TODO: Clock Synchronization is not supported
  % +-------------[ Send initialization ]-------------+
  keep_state_and_data;

%% All other unexpected asdu types
handle_asdu(#asdu{
  type = Type
}, #state{
  settings = #{name := Name}
}) ->
  ?LOGWARNING("~p server received unsupported ASDU type. Type: ~p", [Name, Type]),
  keep_state_and_data.

send_asdu(Priority, ASDU, #state{
  send_queue = SendQueue
}) ->
  SendQueue ! {send_no_confirm, self(), Priority, ASDU}.

build_asdu(Type, COT, PN, Objects, Settings) ->
  [Packet] = iec60870_asdu:build(#asdu{
    type = Type,
    cot = COT,
    pn = PN,
    objects = Objects
  }, Settings),
  Packet.

%%% +--------------------------------------------------------------+
%%% |                     Update Queue Process                     |
%%% +--------------------------------------------------------------+

init_update_queue(Name, Storage, SendQueue) ->
  Owner = self(),
  spawn_link(
    fun() ->
      esubscribe:subscribe(Name, update, self()),
      UpdateQueue = ets:new(update_queue, [
        ordered_set,
        private,
        {read_concurrency, true},
        {write_concurrency, auto}
      ]),
      update_queue(#update_state{
        owner = Owner,
        name = Name,
        storage = Storage,
        update_queue = UpdateQueue,
        send_queue_pid = SendQueue,
        tickets = #{}
      })
    end).

update_queue(#update_state{
  name = Name,
  owner = Owner,
  tickets = Tickets,
  storage = Storage,
  update_queue = UpdateQueue
} = InState) ->
  State =
    receive
      {confirm, TicketRef} ->
        InState#update_state{tickets = maps:remove(TicketRef, Tickets)};
      {Name, update, Update, _, Actor} when Actor =/= self() ->
        Updates = [Object || {Object, _Node, A} <- esubscribe:wait(Name, update, ?ESUBSCRIBE_DELAY), A =/= self()],
        save_update(UpdateQueue, ?UPDATE_PRIORITY, ?COT_SPONT, Update),
        [save_update(UpdateQueue, ?UPDATE_PRIORITY, ?COT_SPONT, DataObject)
          || DataObject <- Updates],
        InState;
      {general_interrogation, Owner, {update_group, GroupID}} ->
        GroupUpdates = collect_group_updates(GroupID, UpdateQueue, Storage),
        [save_update(UpdateQueue, ?COMMAND_PRIORITY, ?COT_SPONT, {IOA, DataObject})
          || {IOA, DataObject} <- GroupUpdates],
        InState;
      {general_interrogation, Owner, GroupID} ->
        GroupUpdates = collect_group_updates(GroupID, UpdateQueue, Storage),
        save_update(UpdateQueue, ?COMMAND_PRIORITY, ?COT_ACTCON, ?C_IC_NA_1),
        [save_update(UpdateQueue, ?COMMAND_PRIORITY, ?COT_GROUP(GroupID), {IOA, DataObject})
          || {IOA, DataObject} <- GroupUpdates],
        save_update(UpdateQueue, ?COMMAND_PRIORITY, ?COT_ACTTERM, ?C_IC_NA_1),
        InState;
      Unexpected ->
        ?LOGWARNING("update queue ~p: received unexpected message: ~p", [Name, Unexpected]),
        InState
    end,
  OutState = check_tickets(Tickets, State),
  update_queue(OutState).

check_tickets(Tickets, #update_state{
  update_queue = UpdateQueue,
  storage = Storage,
  asdu_settings = ASDUSettings,
  send_queue_pid = SendQueuePID
} = State) when map_size(Tickets) =:= 0 ->
  case collect_updates(UpdateQueue, Storage) of
    {[{_IOA, #{type := Type}} | _Rest] = TypeUpdates, Priority, COT} ->
      ListASDU = iec60870_asdu:build(#asdu{
        type = Type,
        cot = COT,
        pn = ?POSITIVE_PN,
        objects = TypeUpdates
      }, ASDUSettings),
      Tickets = lists:foldl(
        fun(ASDU, AccIn) ->
          Ticket = send_update(SendQueuePID, Priority, ASDU),
          AccIn#{Ticket => wait}
        end, #{}, ListASDU),
      State#update_state{tickets = Tickets};
    _ ->
      State
  end;
check_tickets(_Tickets, _State) ->
  ok.

collect_updates(UpdateQueue, Storage) ->
  case ets:first(UpdateQueue) of
    '$end_of_table' ->
      none;
    {Priority, Type, _IOA} = Key ->
      COT = ets:lookup(UpdateQueue, Key),
      Updates = collect_updates(UpdateQueue, Storage, Priority, Type, COT, []),
      {Updates, Priority, COT}
  end.

collect_updates(UpdateQueue, Storage, Priority, Type, COT, AccIn) ->
  case ets:first(UpdateQueue) of
    '$end_of_table' ->
      AccIn;
    {Priority, Type, IOA} = Key ->
      case ets:lookup(UpdateQueue, Key) of
        [] ->
          AccIn;
        [COT] ->
          Acc =
            case ets:lookup(Storage, IOA) of
              [] -> AccIn;
              [DataObject] -> [{IOA, DataObject} | AccIn]
            end,
          ets:delete(UpdateQueue, Key),
          collect_updates(UpdateQueue, Storage, Priority, Type, COT, Acc);
        [_OtherCOT] ->
          AccIn
      end;
    _OtherKey ->
      AccIn
  end.

collect_group_updates(GroupID, UpdateQueue, Storage) ->
  case GroupID of
    ?GLOBAL_GROUP ->
      ets:delete_all_objects(UpdateQueue),
      ets:tab2list(Storage);
    Group when Group >= ?START_GROUP andalso Group =< ?END_GROUP ->
      ets:match_object(Storage, {'_', #{group => GroupID}});
    _ ->
      []
  end.

send_update(SendQueue, Priority, ASDU) ->
  SendQueue ! {send_confirm, self(), Priority, ASDU},
  receive {confirm, TicketRef} -> TicketRef end.

save_update(UpdateQueue, Priority, COT, {IOA, #{type := Type}}) ->
  ets:insert(UpdateQueue, {{Priority, Type, IOA}, COT});
save_update(UpdateQueue, Priority, COT, Type) ->
  ets:insert(UpdateQueue, {{Priority, Type, 0}, COT}).

%%% +--------------------------------------------------------------+
%%% |                      Send Queue Process                      |
%%% +--------------------------------------------------------------+

init_send_queue(Name, Connection) ->
  Owner = self(),
  PID =
    spawn_link(
      fun() ->
        UpdateQueue =
          receive
            {ok, Owner, UpdateQueuePID} -> UpdateQueuePID
          end,
        SendQueue = ets:new(send_queue, [
          ordered_set,
          private,
          {read_concurrency, true},
          {write_concurrency, auto}
        ]),
        send_queue(#send_state{
          owner = Owner,
          name = Name,
          send_queue = SendQueue,
          update_queue_pid = UpdateQueue,
          connection = Connection
        })
      end),
  PID.

send_queue(#send_state{
  update_queue_pid = UpdateQueuePID,
  send_queue = SendQueue,
  owner = Owner
} = State) ->
  receive
    {send_confirm, UpdateQueuePID, Priority, ASDU} ->
      Reference = make_ref(),
      return_confirm(confirm, UpdateQueuePID, Reference),
      ets:insert(SendQueue, {{Priority, Reference}, {confirm, ASDU}});
    {send_no_confirm, Owner, Priority, ASDU} ->
      ets:insert(SendQueue, {{Priority, make_ref()}, {no_confirm, ASDU}})
  end,
  OutState = check_send_queue(State),
  send_queue(OutState).

check_send_queue(#send_state{
  send_queue = SendQueue,
  update_queue_pid = UpdateQueuePID,
  connection = Connection
} = State) ->
  case ets:first(SendQueue) of
    '$end_of_table' ->
      State;
    {_Priority, Reference} = Key ->
      case ets:lookup(SendQueue, Key) of
        [] ->
          ok;
        [{Mode, ASDU}] ->
          SendReference = make_ref(),
          Connection ! {asdu, self(), SendReference, ASDU},
          receive {confirm, SendReference} -> ok end,
          return_confirm(Mode, UpdateQueuePID, Reference)
      end,
      ets:delete(SendQueue, Key),
      State
  end.

return_confirm(confirm, PID, Reference) ->
  PID ! {confirm, Reference};
return_confirm(no_confirm, _PID, _Reference) ->
  ok.