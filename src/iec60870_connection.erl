%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+

%% +--------------------------------------------------------------+
%% |                  Abbreviations cheatsheet                    |
%% +--------------------------------------------------------------+
%% | COA - Common Address                                         |
%% | COT - Cause of Transmission                                  |
%% | IOA - Information Object Address                             |
%% | QDS - Quality Data (Status) Octet                            |
%% | MSB - Most Significant Bit                                   |
%% | LSB - Least Significant Bit                                  |
%% | QOI - Request Pointer (iec60870 GOST 7.2.6.22)                 |
%% |   W - Maximum number of unacknowledged information frames    |
%% |       that can be sent before requiring an acknowledgment    |
%% |   K - Maximum number of frames that can be sent before       |
%% |       a confirmation                                         |
%% |  T1 - Response Timeout                                       |
%% |  T2 - Acknowledgement Timeout                                |
%% |  T2 - Heartbeat Timeout                                      |
%% |   T - Timestamp                                              |
%% | con - Confirmation                                           |
%% | act - Activation                                             |
%% | V(S) - Transmission Status Variable                          |
%% | V(R) - Receive Status Variable                               |
%% | N(S) - Transmitted Sequence Number                           |
%% | N(R) - Accepted Sequence Number                              |
%% | STARTDT - Start Sending Data                                 |
%% | STOPDT  - Stop Sending Data                                  |
%% | TESTFR  - Test Block (Heart Beat)                            |
%% +--------------------------------------------------------------+

%% +--------------------------------------------------------------+
%% |                       APCI Structure                         |
%% +--------------------------------------------------------------+
%% | 1. Start Byte (0x68)                                         |
%% | 2. Length of APDU                                            |
%% | 3. Control Field 1 (CF1)                                     |
%% | 4. Control Field 2 (CF2)                                     |
%% | 5. Control Field 3 (CF3)                                     |
%% | 6. Control Field 4 (CF4)                                     |
%% | Size: 6 bytes                                                |
%% +--------------------------------------------------------------+

%% +--------------------------------------------------------------+
%% |                       ASDU Structure                         |
%% +--------------------------------------------------------------+
%% | 1. TypeID (Type Identification)                              |
%% | 2. SQ (1 bit) | Number Of Objects (7 bits, up to 127)        |
%% | 3. Cause of Transmission (COT) (6 bits)                      |
%% | 4. Common Address of ASDU (COA) (1 or 2 bytes)               |
%% | 5. N Objects ...                                             |
%% +--------------------------------------------------------------+

%% +--------------------------------------------------------------+
%% |                      Object Structure                        |
%% +--------------------------------------------------------------+
%% | 1. Information object address fields (IOA)                   |
%% | 2. Information element (IE)                                  |
%% | 3. Time Tag (Optional field)                                 |
%% +--------------------------------------------------------------+

-module(iec60870_connection).

-include("iec60870.hrl").

-export([
  check_settings/1,
  start_link/2,
  cmd/2
]).

%% +--------------------------------------------------------------+
%% |                           Macros                             |
%% +--------------------------------------------------------------+

-record(parser, {
  coa_bits,
  org_bits,
  ioa_bits
}).

-record(transport, {
  module,
  channel
}).

-record(counters, {
  vs,
  vr,
  vw
}).

-record(state, {
  % +-----------------------+
  % |  Connection Settings  |
  % +-----------------------+
  owner,
  settings,
  parser,
  transport,
  % +------------------------+
  % |  Connection Variables  |
  % +------------------------+
  timer,
  heartbeat,
  buffer,
  counters,
  sent
}).

-define(DEFAULT_SETTINGS, #{
  coa_bytesize => 2,
  org_bytesize => 1,
  ioa_bytesize => 3,
  t2 => 10000,
  coa => 1,
  org => 0,
  k => 12,
  w => 8,
  t3 => infinity
}).

% Each packet (APDU) starts with
-define(START_BYTE, 16#68).

% Packet (APDU) types
-define(U_TYPE, 2#11).
-define(S_TYPE, 2#01).
-define(I_TYPE, 2#00).

% Unnumbered control functions
-define(START_DT_ACTIVATE,   2#000001).
-define(START_DT_CONFIRM,    2#000010).
-define(STOP_DT_ACTIVATE,    2#000100).
-define(STOP_DT_CONFIRM,     2#001000).
-define(TEST_FRAME_ACTIVATE, 2#010000).
-define(TEST_FRAME_CONFIRM,  2#100000).

%% +--------------------------------------------------------------+
%% |                             API                              |
%% +--------------------------------------------------------------+

start_link(Settings, Transport) ->
  OwnerPID = self(),
  ConnectionPID =
    spawn_link(
      fun() ->
        init(OwnerPID, Settings, Transport)
      end),
  receive
    {connected, ConnectionPID} -> ConnectionPID
  end.

cmd(Connection, Command) ->
  Connection ! {cmd, self(), Command}.

%% +--------------------------------------------------------------+
%% |                      Internal functions                      |
%% +--------------------------------------------------------------+

init(OwnerPID, Settings, #{
  settings := TransportSettings,
  module := DriverModule
} = _Transport) ->
  case DriverModule:start(TransportSettings) of
    {ok, Channel} ->
      % Connection is ready
      OwnerPID ! {connected, self()},
      % We need to trap exit from owner to be able to close the transport channel explicitly
      process_flag(trap_exit,true),
      % Enter the loop
      loop(#state{
        settings = maps:without([coa_bytesize, org_bytesize, ioa_bytesize], Settings),
        owner = OwnerPID,
        timer = undefined,
        heartbeat = undefined,
        buffer = <<>>,
        transport = #transport{
          module = DriverModule,
          channel = Channel
        },
        parser = #parser{
          coa_bits = iec60870_lib:bytes_to_bits(maps:get(coa_bytesize, Settings)),
          org_bits = iec60870_lib:bytes_to_bits(maps:get(org_bytesize, Settings)),
          ioa_bits = iec60870_lib:bytes_to_bits(maps:get(ioa_bytesize, Settings))
        },
        counters = #counters{
          vs = 0,
          vr = 0,
          vw = maps:get(w, Settings)
        },
        sent = []
      });
    {error, Error} ->
      throw({transport_error, Error})
  end.

loop(#state{
  transport = Transport,
  owner = OwnerPID,
  buffer = Buffer
} = State) ->
  receive
    {'EXIT', OwnerPID, _Reason} ->
      transport_stop(Transport);
    {'EXIT', PID, Reason} ->
      ?LOGWARNING("unexpected exit signal from ~p, reaason ~p", [PID, Reason]),
      loop(State);
    {cmd, OwnerPID, Command} ->
      % Owner commands
      UpdatedState = handle_command(Command, State),
      loop(UpdatedState);
    {internal, Self, Command} when Self =:= self() ->
      % Internal commands
      UpdatedState = handle_command(Command, State),
      loop(UpdatedState);
    Message ->
      UpdatedState =
        case transport_recv(Transport, Message) of
          {data, Data} ->
            % Data from the transport level is received
            {Packets, TailBuffer} = split_into_packets( <<Buffer/binary, Data/binary>> ),
            State1 = handle_packets(Packets, State),
            State2 = check_heartbeat( State1 ),
            State2#state{buffer = TailBuffer};

          {closed, Reason} ->
            throw({connection_closed, Reason});
          _ ->
            ?LOGWARNING("unexpected message ~p", [Message]),
            State
        end,
      loop(UpdatedState)
  end.

owner_send(Owner, Data) ->
  catch Owner ! {data, self(), Data},
  ok.

transport_send(#transport{module = DriverModule, channel = Channel}, Data) ->
  case DriverModule:send(Channel, Data) of
    ok -> ok;
    {error, Error} -> throw({send_error, Error})
  end.

transport_recv(#transport{module = DriverModule, channel = Channel}, Message) ->
  DriverModule:recv(Channel, Message).

transport_stop(#transport{module = DriverModule, channel = Channel}) ->
  DriverModule:stop(Channel).

handle_command(start_dt_activate, #state{
  transport = Transport
} = State) ->
  transport_send(Transport, create_u_packet(?START_DT_ACTIVATE)),
  State;

handle_command(start_dt_confirm, #state{
  transport = Transport
} = State) ->
  transport_send(Transport, create_u_packet(?START_DT_CONFIRM)),
  check_heartbeat( State );

handle_command(acknowledge, #state{
  counters = #counters{
    vr = VR
  } = Counters,
  settings = #{
    w := W
  },
  timer = Timer,
  transport = Transport
} = State) ->
  UpdatedVR = create_s_packet(VR),
  transport_send(Transport, UpdatedVR),
  check_timer(Timer),
  State#state{
    counters = Counters#counters{vw = W},
    timer = undefined
  };

handle_command(heartbeat, #state{
  heartbeat = { init, _Timer },
  transport = Transport,
  settings = #{ t3 := T3 }
} = State) ->
  transport_send(Transport, create_u_packet(?TEST_FRAME_ACTIVATE)),
  {ok, Timer} = timer:send_after(T3, {internal, self(), heartbeat}),
  State#state{heartbeat = {confirm, Timer}};

handle_command(heartbeat, #state{
  heartbeat = {confirm, _Timer}
}) ->
  throw(heartbeat_timeout);

handle_command({group_request, GroupID}, State) ->
  send_i_packet(?C_IC_NA_1, ?COT_ACT, [{_IOA = 0, GroupID}], State);

handle_command({group_request_confirm, GroupID}, State) ->
  send_i_packet(?C_IC_NA_1, ?COT_ACTCON, [{_IOA = 0, GroupID}], State);

handle_command({group_request_terminate, GroupID}, State) ->
  send_i_packet(?C_IC_NA_1, ?COT_ACTTERM, [{_IOA = 0, GroupID}], State);

handle_command({write_object, IOA, #{type := Type} = Value, COT}, #state{owner = Owner} = State) ->
  Objects = group_objects(Owner, COT, Type),
  COTCode = build_cot_value(COT),
  send_i_packet(Type, COTCode, [{IOA, Value} | Objects], State);

handle_command(InvalidCommand, _State) ->
  throw({invalid_command, InvalidCommand}).

create_apdu(Frame) ->
  Size = byte_size(Frame),
  <<?START_BYTE, Size:8, Frame/binary>>.

%% +--------------------------------------------------------------+
%% |                      Protocol implementation                 |
%% +--------------------------------------------------------------+

split_into_packets(Data) ->
  split_into_packets(Data, []).
split_into_packets(<<?START_BYTE, Size:8, Rest/binary>> = Data, Packets) ->
  case Rest of
    <<Packet:Size/binary, Tail/binary>>->
      split_into_packets(Tail, [Packet | Packets]);
    _ ->
      {lists:reverse(Packets), Data}
  end;
split_into_packets(<<>>, Packets) ->
  {lists:reverse(Packets), <<>>};
split_into_packets(InvalidData, _) ->
  throw({invalid_input_data_format, InvalidData}).

handle_packets([Packet | Rest], State)->
  {Type, Data} = parse_packet(Packet),
  State1 = handle_packet(Type, Data, State),
  handle_packets(Rest, State1);
handle_packets([], State)->
  State.

%% U-type APCI
parse_packet(<<
  Load:6, ?U_TYPE:2, % Control Field 1
  _Ignore:3/binary   % Control Field 2..Control Field 4
>> = Frame) ->
  Data =
    case Load of
      ?TEST_FRAME_ACTIVATE -> test_frame_activate;
      ?TEST_FRAME_CONFIRM  -> test_frame_confirm;
      ?START_DT_ACTIVATE   -> start_dt_activate;
      ?START_DT_CONFIRM    -> start_dt_confirm;
      ?STOP_DT_ACTIVATE    -> stop_dt_activate;
      ?STOP_DT_CONFIRM     -> stop_dt_confirm;
      _-> throw({invalid_u_packet, Frame})
    end,
  {u, Data};

%% S-type APCI
parse_packet(<<
  _:6, ?S_TYPE:2,     % Control Field 1
  _:1/binary,         % Control Field 2
  LSB:7, 0:1,         % Control Field 3
  MSB:8               % Control Field 4
>>) ->
  <<Counter:15>> = <<MSB:8, LSB:7>>,
  {s, Counter};

%% I-type APCI
parse_packet(<<
  LSB_S:7, ?I_TYPE:1, % Control Field 1
  MSB_S:8,            % Control Field 2
  LSB_R:7, 0:1,       % Control Field 3
  MSB_R:8,            % Control Field 4
  ASDU/binary
>>)->
  <<Counter_S:15>> = <<MSB_S:8, LSB_S:7>>,
  <<Counter_R:15>> = <<MSB_R:8, LSB_R:7>>,
  {i, {Counter_S, Counter_R, ASDU}};

parse_packet(InvalidFrame)->
  throw({invalid_frame, InvalidFrame}).

%% +--------------------------------------------------------------+
%% |                        U-type packet                         |
%% +--------------------------------------------------------------+

handle_packet(u, start_dt_confirm, #state{owner = Owner} = State)->
  owner_send(Owner, start_dt_confirm),
  check_heartbeat(State);

handle_packet(u, test_frame_activate, #state{
  transport = Transport
} = State)->
  transport_send(Transport, create_u_packet(?TEST_FRAME_CONFIRM)),
  State;

handle_packet(u, test_frame_confirm, #state{
  heartbeat = {confirm, Timer}
} = State) ->
  timer:cancel(Timer),
  State#state{heartbeat = undefined};

handle_packet(u, Data, #state{owner = Owner} = State)->
  owner_send(Owner, Data),
  State;

%% +--------------------------------------------------------------+
%% |                        S-type packet                         |
%% +--------------------------------------------------------------+

handle_packet(s, ReceiveCounter, #state{
  sent = Sent
} = State) ->
  State#state{ sent = lists:delete( ReceiveCounter, Sent ) };

%% +--------------------------------------------------------------+
%% |                        I-type packet                         |
%% +--------------------------------------------------------------+

handle_packet(i, Packet, #state{
  counters = #counters{vw = 1} = Counters
} = State) ->
  State1 = handle_packet(i, Packet, State#state{counters = Counters#counters{vw = 0}}),
  handle_command(acknowledge, State1);

handle_packet(i, {SendCounter, ReceiveCounter, APDU}, #state{
  counters = #counters{vr = VR, vw = VW} = Counters,
  parser = Parser,
  owner = Owner,
  timer = Timer,
  settings = #{
    t2 := T2
  },
  sent = Sent
} = State) ->
  if
    SendCounter =:= VR -> ok;
    true -> throw({invalid_receive_counter, SendCounter, VR})
  end,
  parse_apdu(APDU, Parser, Owner),
  check_timer(Timer),
  {ok, NewTimer} = timer:send_after(T2, {internal, self(), acknowledge}),
  State#state{
    counters = Counters#counters{
      vr = VR + 1,
      vw = VW - 1
    },
    timer = NewTimer,
    sent = lists:delete(ReceiveCounter, Sent)
  }.

parse_apdu(APDU, #parser{
  coa_bits = COASize,
  org_bits = ORGSize,
  ioa_bits = IOASize
}, Owner)->
  {DUI, ObjectsBin} = parse_dui(COASize, ORGSize, APDU),
  Objects = split_objects(DUI, IOASize, ObjectsBin),
  #{
    type := Type,
    cot := COT,
    pn := PN
  } = DUI,
  ValueCOT = parse_cot_value(COT, PN),
  [begin
    Value = iec60870_type:parse_information_element(Type, Object),
    owner_send(Owner, {object, Type, ValueCOT, Address, Value})
   end || {Address, Object} <- Objects],
  ok.

parse_dui(COASize, ORGSize, 
  <<Type:8,
    SQ:1, NumberOfObjects:7,
    T:1, PN:1, COT:6,
    Rest/binary>>
) ->
  <<ORG:ORGSize,
    COA:COASize/little-integer,
    Body/binary>> = Rest,
  DUI = #{
    type => Type,
    sq   => SQ,
    no   => NumberOfObjects,
    t    => T,
    pn   => PN,
    cot  => COT,
    org  => ORG,
    coa  => COA
  },
  {DUI, Body};

parse_dui(_COASize, _ORGSize, InvalidASDU)->
  throw({invalid_asdu_format, InvalidASDU}).

parse_cot_value(COT, PN)->
  case COT of
    ?COT_PER      -> periodic;
    ?COT_BACK     -> background_interrogation;
    ?COT_SPONT    -> spontaneous;
    ?COT_INIT     -> initialized;
    ?COT_REQ      -> interrogation;
    ?COT_ACT      -> activation;
    ?COT_ACTCON   -> 
      if
        PN =:= 0  -> confirmation_activation;
        true      -> confirmation_activation_reject
      end;
    ?COT_DEACT    -> deactivation;
    ?COT_DEACTCON -> 
      if
        PN =:= 0  -> confirmation_deactivation;
        true      -> confirmation_deactivation_reject
      end;
    ?COT_ACTTERM  -> termination_activation;
    ?COT_RETREM   -> feedback_remote;
    ?COT_RETLOC   -> feedback_local;
    ?COT_FILE     -> file;
    _ when COT >= ?COT_GROUP_MIN, COT =< ?COT_GROUP_MAX-> {group, COT - ?COT_GROUP_MIN};
    _ when COT >= ?COT_GROUP_COUNTER_MIN, COT =< ?COT_GROUP_COUNTER_MAX-> {group_counter, COT - ?COT_GROUP_COUNTER_MIN};
    ?COT_UNKNOWN_TYPE            -> unknown_type;
    ?COT_UNKNOWN_CAUSE           -> unknown_cause;
    ?COT_UNKNOWN_ASDU_ADDRESS    -> unknown_asdu_address;
    ?COT_UNKNOWN_OBJECT_ADDRESS  -> unknown_object_address;
    _-> throw({invalid_cot, COT})
  end.

build_cot_value( COT )->
  case COT of
    periodic                      -> ?COT_PER;
    background_interrogation      -> ?COT_BACK;
    spontaneous                   -> ?COT_SPONT;
    initialized                   -> ?COT_INIT;
    interrogation                 -> ?COT_REQ;
    activation                    -> ?COT_ACT;
    confirmation_activation       -> ?COT_ACTCON;
    confirmation_activation_reject-> ?COT_ACTCON bor 1 bsl 6; % PN = 1
    deactivation                  -> ?COT_DEACT;
    confirmation_deactivation     -> ?COT_DEACTCON;
    confirmation_deactivation_reject->?COT_DEACTCON bor 1 bsl 6; % PN = 1
    termination_activation        -> ?COT_ACTTERM;
    feedback_remote               -> ?COT_RETREM;
    feedback_local                -> ?COT_RETLOC;
    file                          -> ?COT_FILE;
    {group, GroupID}              -> ?COT_GROUP_MIN + GroupID;
    {group_counter, CounterID}    -> ?COT_GROUP_COUNTER_MIN + CounterID;
    unknown_type                  -> ?COT_UNKNOWN_TYPE;
    unknown_cause                 -> ?COT_UNKNOWN_CAUSE;
    unknown_asdu_address          -> ?COT_UNKNOWN_ASDU_ADDRESS;
    unknown_object_address        -> ?COT_UNKNOWN_OBJECT_ADDRESS;
    _-> throw({invalid_cot, COT})
  end.

send_i_packet(Type, COT, DataObjects, #state{
  counters = #counters{
    vs = VS
  } = Counters,
  settings = #{
    w := W,
    k := K
  },
  timer = Timer,
  transport = Transport,
  sent = Sent
} = State) when length(Sent) < K->
  APDU = create_i_packet(Type, COT, DataObjects, State),
  transport_send(Transport, APDU),
  check_timer(Timer),
  State#state{
    counters = Counters#counters{
      vs = VS + 1,
      vw = W
    },
    timer = undefined,
    sent = [ VS+1 | Sent]
  };
send_i_packet(_Type, _COT, _DataObjects, #state{
  settings = #{ k := K }
}) ->
  throw({max_number_of_unconfirmed_packets_reached, K}).

create_u_packet(Code) ->
  create_apdu(<<Code:6, 1:1, 1:1, 0:24>>).

create_s_packet(VR) ->
  <<MSB:8, LSB:7>> = <<VR:15>>,
  create_apdu(<<
    0:6, 0:1, 1:1,
    0:8,
    LSB:7, 0:1,
    MSB:8
  >>).

create_i_packet(Type, COT, DataObjects, #state{
  counters = #counters{
    vr = VR,
    vs = VS
  },
  parser = #parser{
    ioa_bits = IOABitSize,
    org_bits = ORGBitSize,
    coa_bits = COABitSize
  },
  settings = #{
    coa := COA,
    org := ORG
  }
}) ->
  NumberOfObjects = length(DataObjects),
  SQ =
    if
      NumberOfObjects > 1 -> check_sq(DataObjects);
      true -> 0
    end,
  <<MSB_R:8, LSB_R:7>> = <<VR:15>>,
  <<MSB_S:8, LSB_S:7>> = <<VS:15>>,
  InformationObjects = create_information_objects(SQ, Type, DataObjects, IOABitSize),
  create_apdu(<<
    LSB_S:7, 0:1,
    MSB_S:8,
    LSB_R:7, 0:1,
    MSB_R:8,
    Type:8             /integer,
    SQ:1               /integer,
    NumberOfObjects:7  /integer,
    0:1, 0:1, COT:6    /little-integer,
    ORG:ORGBitSize     /little-integer,
    COA:COABitSize     /little-integer,
    InformationObjects /binary
  >>).

%% +--------------------------------------------------------------+
%% |                      Validate settings                       |
%% +--------------------------------------------------------------+

check_settings(InSettings) ->
  Settings0 = maps:with(maps:keys(?DEFAULT_SETTINGS), InSettings),
  Settings = maps:merge(?DEFAULT_SETTINGS, Settings0),
  [check_setting(K, V) || {K, V} <- maps:to_list(Settings)],
  Settings.

check_setting(coa_bytesize, COAByteSize)
  when is_number(COAByteSize), COAByteSize >= ?MIN_COA_BYTES, COAByteSize =< ?MAX_COA_BYTES -> ok;

check_setting(org_bytesize, OrgByteSize)
  when is_number(OrgByteSize), OrgByteSize >= ?MIN_ORG_BYTES, OrgByteSize =< ?MAX_ORG_BYTES -> ok;

check_setting(ioa_bytesize, IOAByteSize)
  when is_number(IOAByteSize), IOAByteSize >= ?MIN_IOA_BYTES, IOAByteSize =< ?MAX_IOA_BYTES -> ok;

check_setting(org, Address)
  when is_number(Address), Address >= ?MIN_ORG, Address =< ?MAX_ORG -> ok;

check_setting(coa, Address)
  when is_number(Address), Address >= ?MIN_COA, Address =< ?MAX_COA -> ok;

check_setting(k, Value)
  when is_number(Value), Value >= ?MIN_FRAME_LIMIT, Value =< ?MAX_FRAME_LIMIT -> ok;

check_setting(w, Value)
  when is_number(Value), Value >= ?MIN_FRAME_LIMIT, Value =< ?MAX_FRAME_LIMIT -> ok;

check_setting(t2, Timeout)
  when is_number(Timeout) -> ok;

check_setting(t3, Timeout)
  when is_number(Timeout); Timeout =:= infinity -> ok;

check_setting(Key, Value)->
  throw({invalid_param, Key, Value}).

%% +--------------------------------------------------------------+
%% |                       Helper functions                       |
%% +--------------------------------------------------------------+

check_timer(Timer)->
  % Reset the acknowledge timer
  if
    Timer =/= undefined ->
      timer:cancel(Timer),
      clear_timer();
    true ->
      ignore
  end.

clear_timer()->
  receive
    {internal, Self, acknowledge} when Self =:= self() -> clear_timer()
  after
    0 -> ok
  end.

check_heartbeat( #state{ heartbeat = { confirm,_ } } = State )->
  % The connection is waiting for heartbeat confirmation
  State;

check_heartbeat( #state{
  heartbeat = HeartBeat,
  settings = #{ t3 := T3 }
  } = State )->

  case HeartBeat of
    {_, Timer}->
      timer:cancel(Timer);
    _-> ignore
  end,

  {ok, NewTimer} = timer:send_after(T3, {internal, self(), heartbeat}),

  State#state{ heartbeat = {init, NewTimer} }.

group_objects(Owner, COT, Type)->
  receive
    {cmd, Owner, {write_object, IOA, #{type := Type} = Value, COT}} ->
      [{IOA, Value} | group_objects( Owner, COT, Type )]
  after
    0 -> []
  end.


