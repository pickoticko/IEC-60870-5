%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+

-module(iec60870_ft12).

-include("iec60870.hrl").
-include("ft12.hrl").

%% +--------------------------------------------------------------+
%% |                           API                                |
%% +--------------------------------------------------------------+
-export([
  check_options/1,
  start_link/1,
  send/2,
  clear/1
]).

% Each packet (APDU) starts with
-define(START_DATA, 16#68).
-define(START_CMD, 16#10).
-define(END_CHAR, 16#16).


start_link( InOptions )->

  Options = maps:merge( #{
    port => required,
    port_options => #{
      mode => active,
      baudrate => 9600,
      parity => 0,
      stopbits => 1,
      bytesize => 8
    },
    address_size => 1
  }, InOptions ),

  check_options( Options ),

  Self = self(),
  PID = spawn_link(fun()-> init( Self, Options ) end),
  receive
    {ready, PID} -> PID;
    {'EXIT' ,PID, Reason}-> throw( Reason )
  end.

send( Port, Frame )->
  Port ! { send, self(), Frame },
  ok.


clear( Port )->
  Port ! { clear, self() },
  ok.

check_options( #{ port := Port } = _Options ) when is_list(Port); is_binary( Port )->
  % TODO. validate other options
  ok;
check_options(_Options )->
  throw( invalid_options ).


-record(state, { owner, port, buffer, address_size }).
init( Owner, #{
  port := PortName,
  port_options := PortOptions,
  address_size := AddressSize
} )->

  case eserial:open( PortName, PortOptions ) of
    {ok, Port} ->
      Owner ! { ready, self() },

      loop( #state{
        owner = Owner,
        port = Port,
        address_size = AddressSize * 8,
        buffer = <<>>
      } );
    {error, Error}->
      exit( Error )
  end.

loop( #state{ port = Port, buffer = Buffer, owner = Owner, address_size = ASize } = State )->
  receive
    {Port, data, Data}->
      case parse_frame( <<Buffer/binary, Data/binary>>, ASize ) of
        { Frame, TailBuffer }->
          Owner ! { data, self(), Frame },
          loop( State#state{ buffer = TailBuffer } );
        TailBuffer ->
          loop( State#state{ buffer = TailBuffer } )
      end;
    {send, Owner, Frame}->
      Packet = build_frame( Frame, ASize ),
      eserial:send( Port, Packet ),
      loop( State );
    {clear, Owner} ->
      % TODO. ClearWindow should be calculated from the baudrate
      timer:sleep( _ClearWindow = 1000 ),
      drop_data( Port ),
      loop( State#state{ buffer = <<>> } )
  end.

drop_data( Port )->
  receive
    {Port, data, _Data}-> drop_data( Port )
  after
    0-> ok
  end.

%% Frame with variable length
parse_frame(<<?START_CMD, _/binary>> = Buffer, AddressSize) ->
  case Buffer of
    <<?START_CMD, CF, Address:AddressSize/little-integer, CS, ?END_CHAR, Tail/binary>> ->
      case control_sum( <<CF, Address>> ) of
        CS ->
          case parse_cf( <<CF>> ) of
            error->
              ?LOGERROR("invalid control field ~p",[ CF ]),
              Tail;
            CFRec ->
              { #frame{
                addr = Address,
                cf = CFRec,
                data = undefined
              }, Tail }
          end;
        Sum->
          ?LOGERROR("invalid control sum ~p",[Sum]),
          Tail
      end;
    _->
      Buffer
  end;
parse_frame(<<?START_DATA, LengthL:8, LengthL:8, ?START_DATA, Body/binary >> = Buffer, AddressSize) ->
  case Body of
    << FrameData:LengthL/binary, CS, ?END_CHAR, Tail/binary >>->
      case control_sum( FrameData ) of
        CS ->
          << CF, Address:AddressSize/little-integer, Data/binary >> = FrameData,
          case parse_cf( <<CF>> ) of
            {ok, CFRec} ->
              { #frame{
                addr = Address,
                cf = CFRec,
                data = Data
              }, Tail };
            error->
              ?LOGERROR("invalid control field ~p",[ CF ]),
              Tail
          end;
        _->
          ?LOGERROR("invalid control sum"),
          Tail
      end;
    _ ->
      Buffer
  end;
parse_frame( <<?START_DATA,_/binary>> = Buffer, _AddressSize )->
  Buffer;
parse_frame( <<_, Tail/binary>>, AddressSize )->
  parse_frame( Tail, AddressSize ).


build_frame( #frame{addr = Address, cf = CFRec, data = Data }, AddressSize ) when is_binary( Data )->
  Body = <<
    Address:AddressSize/little-integer,
    (build_cf( CFRec ))/binary,
    Data/binary
  >>,
  L = size( Body ),
  CS = control_sum( Body ),

  <<?START_DATA, L:8, L:8, ?START_DATA, Body/binary, CS, ?END_CHAR >>;

build_frame( #frame{addr = Address, cf = CFRec }, AddressSize )->
  Body = <<
    (build_cf( CFRec ))/binary,
    Address:AddressSize/little-integer
  >>,
  CS = control_sum( Body ),

  <<?START_CMD, Body/binary, CS, ?END_CHAR>>.

control_sum( Data )->
  control_sum( Data, 0 ).
control_sum(<<X, Rest/binary >>, Sum)->
  control_sum( Rest, Sum + X );
control_sum( <<>>, Sum )->
  Sum rem 256.


parse_cf( <<Dir:1, 1:1, FCB:1, FCV:1, FCode:4>> )->
  #cf_req{
    dir = Dir,
    fcb = FCB,
    fcv = FCV,
    fcode = FCode
  };
parse_cf( <<Dir:1, 0:1, ACD:1, DFC:1, FCode:4>> )->
  #cf_resp{
    dir = Dir,
    acd = ACD,
    dfc = DFC,
    fcode = FCode
  };
parse_cf( _Invalid )->
  error.

build_cf( #cf_req{ dir = Dir, fcb = FCB, fcv = FCV, fcode = FCode } )->
  <<Dir:1, 1:1, FCB:1, FCV:1, FCode:4>>;
build_cf( #cf_resp{ dir = Dir, acd = ACD, dfc = DFC, fcode = FCode } )->
  <<Dir:1, 0:1, ACD:1, DFC:1, FCode:4>>.
