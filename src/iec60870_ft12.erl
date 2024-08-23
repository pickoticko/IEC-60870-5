%%% +----------------------------------------------------------------+
%%% | Copyright (c) 2024. Tokenov Alikhan, alikhantokenov@gmail.com  |
%%% | All rights reserved.                                           |
%%% | License can be found in the LICENSE file.                      |
%%% +----------------------------------------------------------------+

-module(iec60870_ft12).

-include("iec60870.hrl").
-include("ft12.hrl").

%%% +--------------------------------------------------------------+
%%% |                           API                                |
%%% +--------------------------------------------------------------+

-export([
  check_settings/1,
  start_link/1,
  send/2,
  stop/1
]).

%%% +--------------------------------------------------------------+
%%% |                           Macros                             |
%%% +--------------------------------------------------------------+

-record(state, {
  name,
  owner,
  port,
  buffer,
  address_size
}).

-define(DEFAULT_PORT_OPTIONS, #{
  name => undefined,
  mode => active,
  baudrate => 9600,
  parity => 0,
  stopbits => 1,
  bytesize => 8
}).

-define(DEFAULT_OPTIONS, #{
  transport => ?DEFAULT_PORT_OPTIONS,
  address_size => 1
}).

-define(CONNECT_TIMEOUT, 5000).
-define(START_DATA_CHAR, 16#68).
-define(START_CMD_CHAR, 16#10).
-define(END_CHAR, 16#16).

%%% +--------------------------------------------------------------+
%%% |                      API Implementation                      |
%%% +--------------------------------------------------------------+

start_link(InOptions) ->
  Options = maps:merge(?DEFAULT_OPTIONS, InOptions),
  check_settings(Options),
  Self = self(),
  process_flag(trap_exit, true),
  PID = spawn_link(fun() -> init(Self, Options) end),
  receive
    {ready, PID} ->
      PID;
    {'EXIT', PID, Reason} ->
      throw({error, Reason})
  end.

send(Port, Frame) ->
  Port ! {send, self(), Frame},
  ok.

stop(Port) ->
  Port ! {stop, self()}.

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init(Owner, #{
  transport := #{
    type := tcp,
    name := String
  },
  address_size := AddressSize
}) ->
  {ok, {Host, Port}} = parse_tcp_setting(String),
  ?LOGDEBUG("FT12 ~p: trying to connect...", [String]),
  case gen_tcp:connect(Host, Port, [binary, {active, true}, {packet, raw}], ?CONNECT_TIMEOUT) of
    {ok, Socket} ->
      ?LOGDEBUG("FT12 ~p: socket is opened! Socket: ~p", [String, Socket]),
      erlang:monitor(process, Owner),
      Owner ! {ready, self()},
      tcp_loop(#state{
        name = String,
        owner = Owner,
        port = Socket,
        address_size = AddressSize * 8,
        buffer = <<>>
      });
    {error, ConnectError} ->
      exit(ConnectError)
  end;

init(Owner, #{
  transport := #{
    type := serial,
    name := PortName
  } = PortOptions,
  address_size := AddressSize
}) ->
  ?LOGDEBUG("FT12 ~p: trying to open eserial...", [PortName]),
  case eserial:open(PortName, maps:without([type, name], PortOptions)) of
    {ok, Port} ->
      ?LOGDEBUG("FT12 ~p: eserial is opened!", [PortName]),
      erlang:monitor(process, Port),
      erlang:monitor(process, Owner),
      Owner ! {ready, self()},
      serial_loop(#state{
        name = PortName,
        owner = Owner,
        port = Port,
        address_size = AddressSize * 8,
        buffer = <<>>
      });
    {error, Error} ->
      exit(Error)
  end.

tcp_loop(#state{
  name = Name,
  port = Socket,
  owner = Owner,
  buffer = Buffer,
  address_size = AddressSize
} = State) ->
  receive
    {tcp, Socket, Data}->
      TailBuffer =
        case parse_frame(<<Buffer/binary, Data/binary>>, AddressSize) of
          {#frame{} = Frame, Tail} ->
            ?LOGDEBUG("FT12 ~p: received frame: ~p", [Name, Frame]),
            Owner ! {data, self(), Frame},
            Tail;
          {_NoFrame, Tail} ->
            Tail
        end,
      tcp_loop(State#state{buffer = TailBuffer});

    {send, Owner, Frame} ->
      ?LOGDEBUG("FT12 ~p: sending frame: ~p", [Name, Frame]),
      Packet = build_frame(Frame, AddressSize),
      gen_tcp:send(Socket, Packet),
      tcp_loop(State);

    {tcp_closed, Socket} ->
      exit(closed);
    {tcp_error, Socket, Reason} ->
      exit(Reason);
    {tcp_passive, Socket} ->
      exit(tcp_passive);
    {'DOWN', _, process, Owner, Reason} ->
      ?LOGERROR("FT12 ~p: exit by owner, reason: ~p", [Name, Reason]),
      exit(Reason);
    {stop, Owner} ->
      ?LOGDEBUG("FT12 ~p: closed by owner", [Name]),
      gen_tcp:close(Socket);

    Unexpected ->
      ?LOGWARNING("FT12 ~p: unexpected message received ~p", [Name, Unexpected]),
      tcp_loop(State)
  end.

serial_loop(#state{
  port = Port,
  name = PortName,
  buffer = Buffer,
  owner = Owner,
  address_size = AddressSize
} = State) ->
  receive
    {Port, data, Data} ->
      TailBuffer =
        case parse_frame(<<Buffer/binary, Data/binary>>, AddressSize) of
          {#frame{} = Frame, Tail} ->
            ?LOGDEBUG("FT12 ~p: received frame: ~p", [PortName, Frame]),
            Owner ! {data, self(), Frame},
            Tail;
          {_NoFrame, Tail} ->
            Tail
        end,
      ?LOGDEBUG("FT12 ~p: tail buffer: ~p", [PortName, TailBuffer]),
      serial_loop(State#state{buffer = TailBuffer});

    {send, Owner, Frame} ->
      ?LOGDEBUG("FT12 ~p: sending frame: ~p", [PortName, Frame]),
      State1 =
        case Frame#frame.control_field of
          % If the request is reset remote link then we delete all the data from the buffer
          #control_field_request{function_code = _ResetLink = 0} ->
            % TODO: ClearWindow should be calculated from the baudrate
            timer:sleep(_ClearWindow = 100),
            drop_data(Port),
            State#state{buffer = <<>>};
          _ ->
            State
        end,
      Packet = build_frame(Frame, AddressSize),
      eserial:send(Port, Packet),
      serial_loop(State1);

    {stop, Owner} ->
      ?LOGDEBUG("FT12 ~p: closed by owner", [PortName]),
      eserial:close(Port);
    {'DOWN', _, process, Port, Reason} ->
      ?LOGERROR("FT12 ~p: exit by port, reason: ~p",[PortName, Reason]),
      exit(Reason);
    {'DOWN', _, process, Owner, Reason} ->
      ?LOGERROR("FT12 ~p: exit by owner, reason: ~p",[PortName, Reason]),
      exit(Reason)
  end.

parse_frame(Buffer, AddressSize) ->
  parse_frame(Buffer, AddressSize, none).

parse_frame(<<
  ?START_CMD_CHAR,
  _/binary
>> = Buffer, AddressSize, LastFrame) ->
  case Buffer of
    <<?START_CMD_CHAR, ControlField, Address:AddressSize/little-integer, Checksum, ?END_CHAR, Tail/binary>> ->
      case control_sum(<<ControlField, Address:AddressSize/little-integer>>) of
        Checksum ->
          case parse_control_field(<<ControlField>>) of
            error ->
              ?LOGERROR("invalid control field: ~p", [ControlField]),
              parse_frame(Tail, AddressSize, LastFrame);
            CFRec ->
              parse_frame(Tail, AddressSize, #frame{
                address = Address,
                control_field = CFRec,
                data = undefined
              })
          end;
        Sum ->
          ?LOGERROR("invalid control sum: ~p", [Sum]),
          parse_frame(Tail, AddressSize, LastFrame)
      end;
    _ ->
      if
        % Frame length
        size(Buffer) < (4 + AddressSize) ->
          {LastFrame, Buffer};
        true ->
          <<_, TailBuffer/binary>> = Buffer,
          parse_frame(TailBuffer, AddressSize, LastFrame)
      end
  end;
parse_frame(<<
  ?START_DATA_CHAR,
  LengthL:8,
  LengthL:8,
  ?START_DATA_CHAR,
  Body/binary
>> = Buffer, AddressSize, LastFrame) ->
  case Body of
    <<FrameData:LengthL/binary, Checksum, ?END_CHAR, Tail/binary>> ->
      case control_sum(FrameData) of
        Checksum ->
          <<ControlField, Address:AddressSize/little-integer, Data/binary>> = FrameData,
          case parse_control_field(<<ControlField>>) of
            error ->
              ?LOGERROR("invalid control field ~p", [ControlField]),
              parse_frame(Tail, AddressSize, LastFrame);
            CF ->
              parse_frame(Tail, AddressSize, #frame{
                address = Address,
                control_field = CF,
                data = Data
              })
          end;
        _ ->
          ?LOGERROR("invalid control sum"),
          parse_frame(Tail, AddressSize, LastFrame)
      end;
    _ ->
      if
        % Frame length
        size(Body) < (2 + LengthL) ->
          {LastFrame, Buffer};
        true ->
          <<_, TailBuffer/binary>> = Buffer,
          parse_frame(TailBuffer, AddressSize, LastFrame)
      end
  end;
parse_frame(<<?START_DATA_CHAR, _/binary>> = Buffer, _AddressSize, LastFrame) when size(Buffer) < 4 ->
  {LastFrame, Buffer};
parse_frame(<<_, Tail/binary>>, AddressSize, LastFrame) ->
  parse_frame(Tail, AddressSize, LastFrame);
parse_frame(<<>>, _AddressSize, LastFrame) ->
  {LastFrame, <<>>}.

parse_control_field(<<DIR:1, 1:1, FCB:1, FCV:1, FunctionCode:4>>) ->
  #control_field_request{
    direction = DIR,
    fcb = FCB,
    fcv = FCV,
    function_code = FunctionCode
  };

parse_control_field(<<DIR:1, 0:1, ACD:1, DFC:1, FunctionCode:4>>) ->
  #control_field_response{
    direction = DIR,
    acd = ACD,
    dfc = DFC,
    function_code = FunctionCode
  };

parse_control_field(_Invalid) ->
  error.

build_frame(#frame{address = Address, control_field = CFRec, data = Data}, AddressSize) when is_binary(Data) ->
  Body = <<
    (build_control_field(CFRec))/binary,
    Address:AddressSize/little-integer,
    Data/binary
  >>,
  Length = size(Body),
  Checksum = control_sum(Body),
  <<?START_DATA_CHAR, Length, Length, ?START_DATA_CHAR, Body/binary, Checksum, ?END_CHAR>>;

build_frame(#frame{address = Address, control_field = CFRec}, AddressSize) ->
  Body = <<
    (build_control_field(CFRec))/binary,
    Address:AddressSize/little-integer
  >>,
  Checksum = control_sum(Body),
  <<?START_CMD_CHAR, Body/binary, Checksum, ?END_CHAR>>.

build_control_field(#control_field_request{
  direction = DIR,
  fcb = FCB,
  fcv = FCV,
  function_code = FunctionCode
}) ->
  <<DIR:1, 1:1, FCB:1, FCV:1, FunctionCode:4>>;

build_control_field(#control_field_response{
  direction = DIR,
  acd = ACD,
  dfc = DFC,
  function_code = FunctionCode
}) ->
  <<DIR:1, 0:1, ACD:1, DFC:1, FunctionCode:4>>.

%% Calculating control sum of the received packet to verify it
control_sum(Data) ->
  control_sum(Data, 0).

control_sum(<<Head, Rest/binary>>, Sum) ->
  control_sum(Rest, Sum + Head);
control_sum(<<>>, Sum) ->
  Sum rem 256.

%% Clear the process mailbox of these messages
drop_data(Port) ->
  receive
    {Port, data, _Data} -> drop_data(Port)
  after
    0 -> ok
  end.

check_settings(#{transport := TransportSettings}) ->
  case TransportSettings of
    #{type := Type} when (Type =:= tcp) orelse (Type =:= serial) ->
      [check_setting(Type, Setting) || Setting <- maps:to_list(maps:without([type], TransportSettings))];
    Other ->
      throw({invalid_transport_type, Other})
  end,
  ok.

check_setting(tcp, {name, String})
  when is_list(String) -> ok;

check_setting(serial, {name, Name})
  when is_list(Name) -> ok;

check_setting(serial, {baudrate, Baudrate})
  when is_integer(Baudrate) -> ok;

check_setting(serial, {parity, Parity})
  when is_integer(Parity) -> ok;

check_setting(serial, {bytesize, Bytesize})
  when is_integer(Bytesize) -> ok;

check_setting(serial, {stopbits, Stopbits})
  when is_integer(Stopbits) -> ok;

check_setting(Type, Option) ->
  throw({invalid_setting, Type, Option}).

parse_tcp_setting(String) ->
  [Host, Port] = string:split(String, ":"),
  {ok, Address} = inet:parse_address(Host),
  {ok, {Address, list_to_integer(Port)}}.