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
%% | QOI - Request Pointer (iec60870 GOST 7.2.6.22)               |
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

-module(iec60870_104).

-include("iec60870.hrl").
-include("asdu.hrl").

-export([
  start_server/1,
  stop_server/1,
  start_client/1
]).

%% +--------------------------------------------------------------+
%% |                           Macros                             |
%% +--------------------------------------------------------------+

-define(DEFAULT_PORT, 2404).
-define(MAX_PORT_VALUE, 65535).
-define(MIN_PORT_VALUE, 0).

-define(REQUIRED,{?MODULE, required}).

-define(DEFAULT_SETTINGS, #{
  port => ?DEFAULT_PORT,
  t1 => 30000,
  t2 => 5000,
  t3 => 15000,
  k => 12,
  w => 8
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

-define(CONNECT_TIMEOUT, 5000).
-define(WAIT_ACTIVATE, 5000).

-record(state, {
  socket,
  connection,
  settings,
  buffer,
  t1,
  t2,
  t3,
  vs = 0,
  vr = 0,
  vw,
  sent = []
}).

%% +--------------------------------------------------------------+
%% |                             API                              |
%% +--------------------------------------------------------------+

start_server(InSettings) ->
  Root = self(),
  Settings = #{
    port := Port
  } = check_settings(maps:merge(?DEFAULT_SETTINGS, InSettings)),
  case gen_tcp:listen(Port, [binary, {active, true}, {packet, raw}]) of
    {ok, ListenSocket} ->
      wait_connection(ListenSocket, Settings, Root),
      ListenSocket;
    {error, Reason} ->
      throw({transport_error, Reason})
  end.

stop_server(_) ->
  ok.

start_client(InSettings) ->
  Owner = self(),
  Settings = check_settings(maps:merge(?DEFAULT_SETTINGS#{
    host => ?REQUIRED
  }, InSettings)),
  PID = spawn_link(fun() -> init_client(Owner, Settings) end),
  receive
    {ready, PID} -> PID;
    {'EXIT', PID, Reason} -> throw(Reason)
  end.

%% +--------------------------------------------------------------+
%% |                      Init Server Socket                      |
%% +--------------------------------------------------------------+

wait_connection(ListenSocket, Settings, Root)->
  spawn(fun() ->
    process_flag(trap_exit, true),
    link(Root),
    Socket = accept_loop(ListenSocket, Root),
    % Handle the ListenSocket to the next process
    unlink(Root),
    wait_connection(ListenSocket, Settings, Root),
    case wait_activate(Socket, ?START_DT_ACTIVATE, <<>>) of
      {ok, Buffer} ->
        socket_send(Socket, create_u_packet(?START_DT_CONFIRM)),
        case iec60870_server:start_connection(Root, ListenSocket, self() ) of
          {ok, Connection} ->
            init_loop( #state{
              socket = Socket,
              connection = Connection,
              settings = Settings,
              buffer = Buffer
            });
          {error, InternalError} ->
            ?LOGERROR("unable to start a process to handle the incoming connection, error ~p", [InternalError]),
            gen_tcp:close(Socket)
        end;
      {error, ActivateError} ->
        ?LOGWARNING("incoming connection activation error ~p", [ActivateError]),
        gen_tcp:close(Socket)
    end
  end).

accept_loop(ListenSocket, Root) ->
  case gen_tcp:accept(ListenSocket, _Timeout = 2000) of
    {ok, Socket} ->
      Socket;
    {error, timeout} ->
      receive
        {'EXIT', Root, Reason} ->
          timer:sleep(1000),
          catch gen_tcp:close(ListenSocket),
          catch gen_tcp:shutdown(ListenSocket, read_write),
          exit(Reason)
      after
        0 -> accept_loop(ListenSocket, Root)
      end;
    {error, Error} ->
      catch gen_tcp:close(ListenSocket),
      catch gen_tcp:shutdown(ListenSocket, read_write),
      exit(Root, Error),
      exit(Error)
  end.

%% +--------------------------------------------------------------+
%% |                      Init Client Socket                      |
%% +--------------------------------------------------------------+

init_client(Owner, #{
  host := Host,
  port := Port
} = Settings) ->
  case gen_tcp:connect(Host, Port, [binary, {active, true}, {packet, raw}], ?CONNECT_TIMEOUT) of
    {ok, Socket} ->
      %% Sending the activation command and waiting for its confirmation
      socket_send(Socket, create_u_packet(?START_DT_ACTIVATE)),
      case wait_activate( Socket, ?START_DT_CONFIRM, <<>>) of
        {ok, Buffer} ->
          %% The confirmation has been received and the client is ready to work
          Owner ! {ready, self()},
          init_loop( #state{
            socket = Socket,
            connection = Owner,
            settings = Settings,
            buffer = Buffer
          });
        {error, ActivateError} ->
          ?LOGWARNING("client connection activation error: ~p", [ActivateError]),
          gen_tcp:close(Socket),
          throw(ActivateError)
      end;
    {error, ConnectError} ->
      throw(ConnectError)
  end.

%% +--------------------------------------------------------------+
%% |                  Connection Activation Wait                  |
%% +--------------------------------------------------------------+

wait_activate(Socket, Code, Buffer) ->
  receive
    {tcp, Socket, Data} ->
      case <<Buffer/binary, Data/binary>> of
        <<?START_BYTE, 4:8, Code:6, ?U_TYPE:2, _:3/binary, RestBuffer/binary>> ->
          {ok, RestBuffer};
        Head = <<?START_BYTE, _/binary>> when size(Head) < 6 ->
          wait_activate(Socket, Code, Head);
        Unexpected->
          {error, {unexpected_request, Unexpected}}
      end;
    {tcp_closed, Socket} ->
      {error, closed};
    {tcp_error, Socket, Reason} ->
      {error, Reason};
    {tcp_passive, Socket} ->
      {error, tcp_passive}
  after
    ?WAIT_ACTIVATE -> {error, timeout}
  end.

%% +--------------------------------------------------------------+
%% |                      Internal functions                      |
%% +--------------------------------------------------------------+

init_loop(#state{
  connection = Connection,
  settings = #{w := W}
} = State0) ->
  process_flag(trap_exit, true),
  link(Connection),
  State = check_t3(State0),
  loop(State#state{
    vs = 0,
    vr = 0,
    vw = W,
    sent = []
  }).

loop(#state{
  connection = Connection,
  buffer = Buffer,
  socket = Socket
} = State) ->
  receive
    %% Data is received from the transport
    {tcp, Socket, Data}->
      {Packets, TailBuffer} = split_into_packets(<<Buffer/binary, Data/binary>>),
      State1 = handle_packets(Packets, State),
      State2 = check_t3(State1),
      loop(State2#state{buffer = TailBuffer});
    %% A packet is received from the connection
    {asdu, Connection, ASDU} ->
      State1 = send_i_packet(ASDU, State),
      State2 = check_t1(State1),
      loop(State2);
    %% Commands that were sent to self, others are ignored and unexpected
    {Self, Command} when Self =:= self() ->
      State1 = handle_command(Command, State),
      loop(State1);
    {tcp_closed, Socket} ->
      exit(closed);
    {tcp_error, Socket, Reason} ->
      exit(Reason);
    {tcp_passive, Socket} ->
      exit(tcp_passive);
    {'EXIT', Connection, _Reason} ->
      gen_tcp:close(Socket);
    Unexpected->
      ?LOGWARNING("unexpected message ~p", [Unexpected]),
      loop(State)
  end.

handle_command(t1, _State) ->
  throw(confirm_timeout);

handle_command(t2, #state{
  socket = Socket,
  vr = VR,
  settings = #{
    w := W
  }
} = State) ->
  UpdatedVR = create_s_packet(VR),
  socket_send(Socket, UpdatedVR),
  State#state{
    vw = W
  };

handle_command(t3, #state{
  t3 = {init, _Timer},
  socket = Socket,
  settings = #{t3 := T3}
} = State) ->
  socket_send(Socket, create_u_packet(?TEST_FRAME_ACTIVATE)),
  {ok, Timer} = timer:send_after(T3, {self(), t3}),
  State#state{t3 = {confirm, Timer}};

handle_command(t3, #state{
  t3 = {confirm, _Timer}
}) ->
  throw(heartbeat_timeout);

handle_command(InvalidCommand, _State) ->
  throw({invalid_command, InvalidCommand}).

%% Attaching the beginning of the packet and its size to the frame
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

%% +--------------------------------------------------------------+
%% |                       Packet parsing                         |
%% +--------------------------------------------------------------+

%% U-type APCI
parse_packet(<<
  Load:6, ?U_TYPE:2,  % Control Field 1
  _Ignore:3/binary    % Control Field 2..Control Field 4
>>) ->
  {u, Load};

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
%% |                      Packet creation                         |
%% +--------------------------------------------------------------+

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

create_i_packet(ASDU, #state{
  vr = VR,
  vs = VS
}) ->
  <<MSB_R:8, LSB_R:7>> = <<VR:15>>,
  <<MSB_S:8, LSB_S:7>> = <<VS:15>>,
  create_apdu(<<
    LSB_S:7, 0:1,
    MSB_S:8,
    LSB_R:7, 0:1,
    MSB_R:8,
    ASDU/binary
  >>).

%% +--------------------------------------------------------------+
%% |                        U-type packet                         |
%% +--------------------------------------------------------------+

handle_packet(u, ?START_DT_CONFIRM, State)->
  ?LOGWARNING("unexpected START_DT_CONFIRM packet was received!"),
  State;

handle_packet(u, ?TEST_FRAME_ACTIVATE, #state{
  socket = Socket
} = State) ->
  socket_send(Socket, create_u_packet(?TEST_FRAME_CONFIRM)),
  State;

handle_packet(u, ?TEST_FRAME_CONFIRM, #state{
  t3 = {confirm, Timer}
} = State) ->
  reset_timer(t3, Timer),
  State#state{t3 = undefined};

handle_packet(u, _Data, State)->
  % TODO: Is it correct to ignore other types of U packets?
  State;

%% +--------------------------------------------------------------+
%% |                        S-type packet                         |
%% +--------------------------------------------------------------+

handle_packet(s, ReceiveCounter, #state{
  sent = Sent,
  t1 = T1
} = State) ->
  reset_timer(t1, T1),
  State#state{
    t1 = undefined,
    sent = [S || S <- Sent, S > ReceiveCounter]
  };

%% +--------------------------------------------------------------+
%% |                        I-type packet                         |
%% +--------------------------------------------------------------+

handle_packet(i, Packet, #state{
  vw = 1
} = State) ->
  State1 = handle_packet(i, Packet, State#state{vw = 0}),
  % Sending an acknowledge because the number of
  % unacknowledged i-packets is reached its limit
  handle_command(t2, State1);

handle_packet(i, {SendCounter, ReceiveCounter, ASDU}, #state{
  vr = VR,
  vw = VW,
  connection = Connection,
  t1 = T1,
  sent = Sent
} = State) ->
  if
    SendCounter =:= VR -> ok;
    true -> throw({invalid_receive_counter, SendCounter, VR})
  end,
  Connection ! {asdu, self(), ASDU},
  reset_timer(t1, T1),
  State1 = check_t2(State),
  State1#state{
    vr = VR + 1,
    vw = VW - 1,
    sent = [S || S <- Sent, S > ReceiveCounter]
  }.

send_i_packet(ASDU, #state{
  vs = VS,
  settings = #{
    w := W,
    k := K
  },
  socket = Socket,
  sent = Sent
} = State) ->
  if
    length(Sent) =< K ->
      APDU = create_i_packet(ASDU, State),
      socket_send(Socket, APDU);
    true ->
      exit({max_number_of_unconfirmed_packets_reached, K})
  end,
  State#state{
    vs = VS + 1,
    vw = W,
    sent = [VS + 1 | Sent]
  }.

%% +--------------------------------------------------------------+
%% |                      Validate settings                       |
%% +--------------------------------------------------------------+

check_settings(Settings) ->
  SettingsList = maps:to_list( maps:merge(?DEFAULT_SETTINGS, Settings) ),
  case [S || {S, ?REQUIRED} <- SettingsList] of
    [] -> ok;
    Required -> throw( {required, Required} )
  end,
  case maps:keys(Settings) -- [host | maps:keys(?DEFAULT_SETTINGS)] of
    [] -> ok;
    InvalidParams -> throw({invalid_params, InvalidParams} )
  end,
  maps:from_list([{K, check_setting(K, V)} || {K, V} <- SettingsList]).

check_setting(host, Host) when is_tuple( Host) ->
  case tuple_to_list(Host) of
    IP when length(IP) =:= 4 ->
      case [Octet || Octet <- IP, is_integer(Octet), Octet >= 0, Octet =< 255] of
        IP -> Host;
        _  -> throw({invalid_host, Host})
      end;
    _ -> throw({invalid_host, Host})
  end;

check_setting(port, Port)
  when is_number(Port), Port >= ?MIN_PORT_VALUE, Port =< ?MAX_PORT_VALUE -> Port;

check_setting(k, Value)
  when is_number(Value), Value >= ?MIN_FRAME_LIMIT, Value =< ?MAX_FRAME_LIMIT -> Value;

check_setting(w, Value)
  when is_number(Value), Value >= ?MIN_FRAME_LIMIT, Value =< ?MAX_FRAME_LIMIT -> Value;

check_setting(t1, Timeout)
  when is_number(Timeout) -> Timeout;

check_setting(t2, Timeout)
  when is_number(Timeout) -> Timeout;

check_setting(t3, Timeout)
  when is_number(Timeout); Timeout =:= infinity -> Timeout;

check_setting(Key, Value)->
  throw({invalid_param, Key, Value}).

%% +--------------------------------------------------------------+
%% |                       Helper functions                       |
%% +--------------------------------------------------------------+

%% Confirmation timeout check
check_t1(#state{
  t1 = Timer,
  settings = #{t1 := T1}
} = State) ->
  reset_timer(t1, Timer),
  {ok, NewTimer} = timer:send_after(T1, {self(), t1}),
  State#state{
    t1 = NewTimer
  }.

check_t2(#state{
  t2 = Timer,
  settings = #{t2 := T2}
} = State) ->
  reset_timer(t1, Timer),
  {ok, NewTimer} = timer:send_after(T2, {self(), t2}),
  State#state{
    t2 = NewTimer
  }.

check_t3(#state{
  t3 = {confirm, _}
} = State) ->
  State;

check_t3(#state{
  t3 = Heartbeat,
  settings = #{t3 := T3}
} = State) ->
  case Heartbeat of
    {_, Timer} ->
      reset_timer(t3, Timer);
    _ ->
      ignore
  end,
  {ok, NewTimer} = timer:send_after(T3, {self(), t3}),
  State#state{
    t3 = {init, NewTimer}
  }.

reset_timer(Type, Timer) ->
  if
    Timer =/= undefined ->
      timer:cancel(Timer),
      clear_timer(Type);
    true ->
      ignore
  end,
  ok.

%% Clearing the mailbox from timer messages
clear_timer(Type) ->
  receive
    {Self, Type} when Self =:= self() -> clear_timer( Type )
  after
    0 -> ok
  end.

socket_send(Socket, Data) ->
  case gen_tcp:send(Socket, Data) of
    ok -> ok;
    {error, Error} -> throw({send_error, Error})
  end.


