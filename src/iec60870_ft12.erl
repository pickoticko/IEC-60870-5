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
  check_options/1,
  start_link/1,
  send/2,
  purge/1,
  stop/1
]).

%%% +--------------------------------------------------------------+
%%% |                           Macros                             |
%%% +--------------------------------------------------------------+

-record(state, {
  owner,
  port,
  buffer,
  address_size
}).

-define(DEFAULT_PORT_OPTIONS, #{
  mode => active,
  baudrate => 9600,
  parity => 0,
  stopbits => 1,
  bytesize => 8
}).

-define(DEFAULT_OPTIONS, #{
  port => required,
  port_options => ?DEFAULT_PORT_OPTIONS,
  address_size => 1
}).

-define(START_DATA_CHAR, 16#68).
-define(START_CMD_CHAR, 16#10).
-define(END_CHAR, 16#16).

%%% +--------------------------------------------------------------+
%%% |                      API Implementation                      |
%%% +--------------------------------------------------------------+

start_link(InOptions) ->
  Options = maps:merge(?DEFAULT_OPTIONS, InOptions),
  check_options(Options),
  Self = self(),
  PID = spawn_link(fun() -> init(Self, Options) end),
  receive
    {ready, PID} -> PID;
    {'EXIT', PID, Reason} -> throw(Reason)
  end.

send(Port, Frame) ->
  Port ! {send, self(), Frame},
  ok.

purge( Port ) ->
  Port ! {purge, self()},
  ok.

stop(Port) ->
  Port ! {stop, self()}.

check_options(#{port := Port} = _Options) when is_list(Port); is_binary(Port) ->
  % TODO. validate other options
  ok;
check_options(_) ->
  throw(invalid_options).

%%% +--------------------------------------------------------------+
%%% |                      Internal functions                      |
%%% +--------------------------------------------------------------+

init(Owner, #{
  port := PortName,
  port_options := PortOptions,
  address_size := AddressSize
}) ->
  case eserial:open(PortName, PortOptions) of
    {ok, Port} ->
      Owner ! {ready, self()},
      loop(#state{
        owner = Owner,
        port = Port,
        address_size = AddressSize * 8,
        buffer = <<>>
      });
    {error, Error} ->
      exit(Error)
  end.

loop(#state{
  port = Port,
  buffer = Buffer,
  owner = Owner,
  address_size = AddressSize
} = State) ->
  receive
    {Port, data, Data} ->
      case parse_frame(<<Buffer/binary, Data/binary>>, AddressSize) of
        {Frame, TailBuffer} ->
          Owner ! {data, self(), Frame},
          loop(State#state{buffer = TailBuffer});
        TailBuffer ->
          loop(State#state{buffer = TailBuffer})
      end;

    {send, Owner, Frame} ->
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
      loop(State1);

    {purge, Owner} ->
      drop_data(Port),
      loop( State#state{buffer = <<>>} );
    {stop, Owner} ->
      eserial:close(Port)
  end.

parse_frame(<<
  ?START_CMD_CHAR,
  _/binary
>> = Buffer, AddressSize) ->
  case Buffer of
    <<?START_CMD_CHAR, ControlField, Address:AddressSize/little-integer, Checksum, ?END_CHAR, Tail/binary>> ->
      case control_sum(<<ControlField, Address:AddressSize/little-integer>>) of
        Checksum ->
          case parse_control_field(<<ControlField>>) of
            error ->
              ?LOGERROR("invalid control field: ~p", [ControlField]),
              Tail;
            CFRec ->
              {#frame{
                address = Address,
                control_field = CFRec,
                data = undefined
              }, Tail}
          end;
        Sum ->
          ?LOGERROR("invalid control sum: ~p", [Sum]),
          Tail
      end;
    _ ->
      if
        % Frame length
        size(Buffer) < (4 + AddressSize) ->
          Buffer;
        true ->
          <<_, TailBuffer/binary>> = Buffer,
          parse_frame(TailBuffer, AddressSize)
      end
  end;

parse_frame(<<
  ?START_DATA_CHAR,
  LengthL:8,
  LengthL:8,
  ?START_DATA_CHAR,
  Body/binary
>> = Buffer, AddressSize) ->
  case Body of
    <<FrameData:LengthL/binary, Checksum, ?END_CHAR, Tail/binary>> ->
      case control_sum(FrameData) of
        Checksum ->
          <<ControlField, Address:AddressSize/little-integer, Data/binary>> = FrameData,
          case parse_control_field(<<ControlField>>) of
            error ->
              ?LOGERROR("invalid control field ~p", [ControlField]),
              Tail;
            CF ->
              {#frame{
                address = Address,
                control_field = CF,
                data = Data
              }, Tail}
          end;
        _ ->
          ?LOGERROR("invalid control sum"),
          Tail
      end;
    _ ->
      if
        % Frame length
        size(Body) < (2 + LengthL) ->
          Buffer;
        true ->
          <<_, TailBuffer/binary>> = Buffer,
          parse_frame(TailBuffer, AddressSize)
      end
  end;

parse_frame(<<?START_DATA_CHAR, _/binary>> = Buffer, _AddressSize) when size(Buffer) < 4 ->
  Buffer;

parse_frame(<<_, Tail/binary>>, AddressSize) ->
  parse_frame(Tail, AddressSize);

parse_frame(<<>>, _AddressSize) ->
  <<>>.

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