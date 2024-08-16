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


-record(send_state, {
  owner,
  name,
  tickets,
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
  storage := Storage,
  asdu := ASDUSettings
} = Settings}) ->
  ?LOGINFO("server ~p: initiating incoming connection...", [Name]),
  {ok, SendQueue} = start_link_send_queue(Name, Connection),
  {ok, UpdateQueue} = start_link_update_queue(Name, Storage, SendQueue, ASDUSettings),
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

% ??? We have to exit SendQueue and UpdateQueue if the reason is normal
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
            send_asdu(?REMOTE_CONTROL_PRIORITY, NegativeConfirmation, State);
          ok ->
            %% +------------[ Activation confirmation ]-------------+
            Confirmation = build_asdu(Type, ?COT_ACTCON, ?POSITIVE_PN, Objects, ASDUSettings),
            send_asdu(?REMOTE_CONTROL_PRIORITY, Confirmation, State),
            %% +------------[ Activation termination ]--------------+
            Termination = build_asdu(Type, ?COT_ACTTERM, ?POSITIVE_PN, Objects, ASDUSettings),
            send_asdu(?REMOTE_CONTROL_PRIORITY, Termination, State)
        end
      catch
        _Exception:Reason ->
          ?LOGERROR("remote control handler failed. Reason: ~p", [Reason]),
          %% +-------[ Negative activation confirmation ]---------+
          ExceptionNegConfirmation = build_asdu(Type, ?COT_ACTCON, ?NEGATIVE_PN, Objects, ASDUSettings),
          send_asdu(?REMOTE_CONTROL_PRIORITY, ExceptionNegConfirmation, State)
      end;
    true ->
      %% +-------[ Negative activation confirmation ]---------+
      ?LOGWARNING("remote control request accepted but no handler is defined"),
      NegativeConfirmation = build_asdu(Type, ?COT_ACTCON, ?NEGATIVE_PN, Objects, ASDUSettings),
      send_asdu(?REMOTE_CONTROL_PRIORITY, NegativeConfirmation, State)
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
%%% | Description: update queue process is responsible only for    |
%%% | the incoming updates from the esubscribe and handling GI     |
%%% | requests from the server state machine process               |
%%% +--------------------------------------------------------------+
%%% | Update queue ETS format: {Priority, Type, IOA} => COT        |
%%% +--------------------------------------------------------------+

% order ets:
% { { pointer, ioa }, true }

% #pointer{ priority, type, cot }
-record(update_state, {
  owner,
  name,
  tickets,
  update_queue_ets,
  ioa_index,
  send_queue_pid,
  asdu_settings,
  pointer,
  storage,
  gi_termination
}).

start_link_update_queue(Name, Storage, SendQueue, ASDUSettings) ->
  Owner = self(),
  {ok, spawn_link(
    fun() ->
      esubscribe:subscribe(Name, update, self()),
      UpdateQueue = ets:new(update_queue, [
        ordered_set,
        private
      ]),
      IOA_Index = ets:new(io_index, [
        set,
        private
      ]),

      update_queue(#update_state{
        owner = Owner,
        name = Name,
        storage = Storage,
        update_queue_ets = UpdateQueue,
        ioa_index = IOA_Index,
        send_queue_pid = SendQueue,
        asdu_settings = ASDUSettings,
        pointer = ets:first(UpdateQueue), % ???
        tickets = #{},
        gi_termination = undefined
      })
    end)}.

update_queue(#update_state{
  name = Name,
  owner = Owner,
  tickets = Tickets,
  storage = Storage,
  send_queue_pid = SendQueuePID,
  asdu_settings = ASDUSettings,
  gi_termination = GI_Termination
} = InState) ->
  State =
    receive
%%--------------REAL-TIME updates-------------------------------------------------------
      {Name, update, Update, _, Actor} when Actor =/= Owner ->
        enqueue_update(?UPDATE_PRIORITY, ?COT_SPONT, Update, InState),
        InState;

%%--------------ASDU sent confirmation-------------------------------------------------------
      {confirm, TicketRef} ->
        InState#update_state{tickets = maps:remove(TicketRef, Tickets)};

%%----------GROUP INTERROGATION----------------------------------------------------------
      {general_interrogation, Owner, {update_group, _GroupID}} when is_binary(GI_Termination) ->
        % Ignore request
        InState;
      {general_interrogation, Owner, GroupID} when is_binary(GI_Termination)->
        % Reject GI request
        [Reject] = iec60870_asdu:build(#asdu{
          type = ?C_IC_NA_1,
          pn = ?NEGATIVE_PN,
          cot = ?COT_ACTCON,
          objects = [{_IOA = 0, GroupID}]
        }, ASDUSettings),

        SendQueuePID ! {send_no_confirm, self(), ?COMMAND_PRIORITY, Reject},
        InState;
      {general_interrogation, Owner, {update_group, GroupID}} ->
        GroupUpdates = collect_group_updates(GroupID, Storage),
        % ??? ets:insert(UpdateQueue, [{{Priority, Type, IOA}, COT}]);
        [enqueue_update(?COMMAND_PRIORITY, ?COT_SPONT, {IOA, DataObject}, InState)
          || {IOA, DataObject} <- GroupUpdates],
        InState;
      {general_interrogation, Owner, GroupID} ->

        [Confirmation] = iec60870_asdu:build(#asdu{
          type = ?C_IC_NA_1,
          pn = ?POSITIVE_PN,
          cot = ?COT_ACTCON,
          objects = [{_IOA = 0, GroupID}]
        }, ASDUSettings),
        SendQueuePID ! {send_no_confirm, self(), ?COMMAND_PRIORITY, Confirmation},

        % Enqueue group updates
        GroupUpdates = collect_group_updates(GroupID, Storage),
        [enqueue_update(?COMMAND_PRIORITY, ?COT_GROUP(GroupID), {IOA, DataObject}, InState)
          || {IOA, DataObject} <- GroupUpdates],

        % Keep the termination
        [Termination] = iec60870_asdu:build(#asdu{
          type = ?C_IC_NA_1,
          pn = ?POSITIVE_PN,
          cot = ?COT_ACTTERM,
          objects = [{0, GroupID}]  % _IOA = 0
        }, ASDUSettings),

        InState#update_state{ gi_termination = Termination };
%%-----------------------------------------------------------------------------------
      Unexpected ->
        ?LOGWARNING("update queue ~p: received unexpected message: ~p", [Name, Unexpected]),
        InState
    end,
  OutState = check_tickets( State ),
  update_queue(OutState).

%%% +--------------------------------------------------------------+
%%% |                      Helper functions                        |
%%% +--------------------------------------------------------------+
-record(pointer,{priority, cot, type}).
-record(order, {pointer, ioa }).

check_tickets( #update_state{
  tickets = Tickets
} = State ) when map_size(Tickets) > 0->
  State;
check_tickets( InState )->
  case next_queue( InState ) of
    '$end_of_table' ->
      InState;
    NextPointer->
      State = check_gi_termination(NextPointer, InState),
      Updates = get_pointer_updates( NextPointer, State ),

      send_updates(Updates, NextPointer, State)
  end.

next_queue(#update_state{
  pointer = '$end_of_table',
  update_queue_ets = UpdateQueue
})->
  case ets:first( UpdateQueue ) of
    #order{ pointer = Pointer }-> Pointer;
    _-> '$end_of_table'
  end;
next_queue(#update_state{
  pointer = #pointer{} = Pointer,
  update_queue_ets = UpdateQueue
} = State)->
  case ets:next( UpdateQueue, #order{ pointer = Pointer, ioa = max_ioa } ) of
    #order{ pointer = NextPointer }->
      NextPointer;
    _->
      % Start from the beginning
      next_queue( State#update_state{ pointer = '$end_of_table'  } )
  end.

check_gi_termination(#pointer{
  cot = NextCOT
}, #update_state{
  pointer = #pointer{ cot = COT },
  gi_termination = GI_Termination,
  send_queue_pid = SendQueuePID
}= State) when
  (COT >= ?COT_GROUP_MIN andalso COT =< ?COT_GROUP_MAX) andalso NextCOT =/= COT ->

  SendQueuePID ! {send_no_confirm, self(), ?COMMAND_PRIORITY, GI_Termination},
  State#update_state{ gi_termination = undefined }.

get_pointer_updates(NextPointer, #update_state{
  update_queue_ets = UpdateQueue
}= State)->
  get_pointer_updates(ets:next( UpdateQueue, #order{ pointer = NextPointer, ioa = -1 } ),  NextPointer, State).

get_pointer_updates(#order{ pointer = NextPointer, ioa = IOA} = Order, NextPointer, #update_state{
  update_queue_ets = UpdateQueue,
  ioa_index = IOA_Index,
  storage = Storage
} =State)->

  ets:delete( UpdateQueue, Order ),
  ets:delete( IOA_Index, IOA ),

  case ets:lookup( Storage, IOA ) of
    [ Update ] ->
      [Update|get_pointer_updates(ets:next( UpdateQueue, Order),  NextPointer, State)];
    []->
      get_pointer_updates(ets:next( UpdateQueue, Order),  NextPointer, State)
  end;
get_pointer_updates(_NextKey, _NextPointer, _State)->
  [].

send_updates(Updates, #pointer{
  priority = Priority,
  type = Type,
  cot = COT
} = Pointer, #update_state{
  asdu_settings = ASDUSettings,
  send_queue_pid = SendQueuePID
} =State)->

  ListASDU = iec60870_asdu:build(#asdu{
    type = Type,
    cot = COT,
    pn = ?POSITIVE_PN,
    objects = Updates
  }, ASDUSettings),

  Tickets = lists:foldl(
    fun(ASDU, AccIn) ->
      Ticket = send_update(SendQueuePID, Priority, ASDU),
      AccIn#{Ticket => wait}
    end, #{}, ListASDU),

  State#update_state{
    tickets = Tickets,
    pointer = Pointer
  }.

collect_group_updates(GroupID, Storage) ->
  case GroupID of
    ?GLOBAL_GROUP ->
      ets:tab2list(Storage);
    Group when Group >= ?START_GROUP andalso Group =< ?END_GROUP ->
      ets:match_object(Storage, {'_', #{group => GroupID}});
    _ ->
      []
  end.

send_update(SendQueue, Priority, ASDU) ->
  SendQueue ! {send_confirm, self(), Priority, ASDU},
  receive {accepted, TicketRef} -> TicketRef end.

%% Updating the ETS table
%% Search description: we are looking for the existing IOA
%% - If it’s not found, insert the new update;
%% - If it is found, replace the existing data only if the
%%   new update has equal or lower priority;
%% - If it is found and current update has lower priority,
%%   then do nothing.
enqueue_update(Priority, COT, {IOA, #{type := Type}}, #update_state{
  ioa_index = IOA_Index,
  update_queue_ets = UpdateQueue
}) ->
  Order = #order{
    pointer = #pointer{ priority = Priority, cot = COT, type = Type },
    ioa = IOA
  },
  case ets:lookup( IOA_Index, IOA ) of
    [] ->
      ets:insert( UpdateQueue, { Order, true } ),
      ets:insert( IOA_Index, {IOA, Order} );
    [{#order{ pointer = #pointer{ priority = HasPriority } },_}] when HasPriority < Priority->
      % We cannot lower the existing priority
      ignore;
    [{PrevOrder,_}]->
      ets:delete( UpdateQueue, PrevOrder ),
      ets:insert( UpdateQueue, { Order, true } ),
      ets:insert( IOA_Index, {IOA, Order} )
  end.

%%% +--------------------------------------------------------------+
%%% |                      Send Queue Process                      |
%%% +--------------------------------------------------------------+
%%% | Description: send queue process is ONLY responsible for      |
%%% | sending data from state machine process to the connection    |
%%% | process (i.e. transport level).                              |
%%% +--------------------------------------------------------------+
%%% | Send queue ETS format: {Priority, Ref} => ASDU               |
%%% +--------------------------------------------------------------+

start_link_send_queue(Name, Connection) ->
  Owner = self(),
  {ok, spawn_link(
    fun() ->
      SendQueue = ets:new(send_queue, [
        ordered_set,
        private
      ]),
      send_queue(#send_state{
        owner = Owner,
        name = Name,
        send_queue = SendQueue,
        connection = Connection,
        tickets = #{}
      })
    end)}.

send_queue(#send_state{
  send_queue = SendQueue,
  owner = Owner,
  tickets = Tickets
} = InState) ->
  State =
    receive
      {confirm, Reference} ->
        return_confirmation(Tickets, Reference),
        InState#send_state{tickets = maps:remove(Reference, Tickets)};
      {send_confirm, Sender, Priority, ASDU} ->
        Reference = make_ref(),
        Sender ! {accepted, Reference},
        ets:insert(SendQueue, {{Priority, Reference}, {Sender, ASDU}}),
        InState;
      {send_no_confirm, Owner, Priority, ASDU} ->
        ets:insert(SendQueue, {{Priority, make_ref()}, {none, ASDU}}),
        InState
    end,
  OutState = check_send_queue(State),
  send_queue(OutState).

check_send_queue(#send_state{
  send_queue = SendQueue,
  connection = Connection,
  tickets = Tickets
} = InState) when map_size(Tickets) =:= 0 ->
  case ets:first(SendQueue) of
    '$end_of_table' ->
      InState;
    {_Priority, Reference} = Key ->
      % We save the ticket to wait for confirmation for this process
      [{_Key, {Sender, ASDU}}] = ets:take(SendQueue, Key),
      send_to_connection(Connection, Reference, ASDU),
      InState#send_state{tickets = Tickets#{Reference => Sender}}
  end;
check_send_queue(#send_state{} = State) ->
  State.

%%% +--------------------------------------------------------------+
%%% |                      Helper functions                        |
%%% +--------------------------------------------------------------+

return_confirmation(Tickets, Reference) ->
  case Tickets of
    #{Reference := Sender} when is_pid(Sender) ->
      Sender ! {confirm, Reference};
    _Other ->
      ok
  end.

send_to_connection(Connection, Reference, ASDU) ->
  Connection ! {asdu, self(), Reference, ASDU}.