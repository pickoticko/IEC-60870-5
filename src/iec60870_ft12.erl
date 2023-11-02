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
  start_link/2,
  send/2,
  clear/1
]).

%%%% Function codes of unbalanced transmission from primary station
%%-define(RESET_REMOTE_LINK, 0).
%%-define(RESET_USER_PROCESS, 1).
%%-define(USER_DATA_CONFIRM, 3).
%%-define(USER_DATA_NO_REPLY, 4).
%%-define(EXPECTED_RESPONSE, 8).
%%-define(REQUEST_STATUS_LINK, 9).
%%-define(REQUEST_DATA_CLASS_ONE, 10).
%%-define(REQUEST_DATA_CLASS_TWO, 11).
%%-define(REMOTE_LINK_RESET, 0).
%%
%%%% Function codes of unbalanced transmission from secondary station
%%-define(CONFIRM_ACKNOWLEDGEMENT, 0).
%%-define(NOT_CONFIRMED_LINK_BUSY, 1).
%%-define(USER_DATA, 8).
%%-define(USER_DATA_NOT_AVAILABLE, 9).
%%-define(STATUS_LINK_DEMAND, 11).
%%-define(LINK_SERVICE_NOT_FUNCTIONING, 14).
%%-define(LINK_SERVICE_NOT_IMPLEMENTED, 15).

% Each packet (APDU) starts with
-define(START_DATA, 16#68).
-define(START_CMD, 16#10).
-define(END_CHAR, 16#16).


start_link( Port, Options )->
  Self = self(),
  PID = spawn_link(fun()-> init( Self, Port, Options ) end),
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

-record(state, { owner, port, buffer }).
init( Owner, Port, Options )->
  case eserial:open( Port, Options ) of
    {ok, Port} ->
      Owner ! { ready, self() },
      loop( #state{
        owner = Owner,
        port = Port,
        buffer = <<>>
      } );
    {error, Error}->
      exit( Error )
  end.

loop( #state{ port = Port, buffer = Buffer, owner = Owner } = State )->
  receive
    {Port, data, Data}->
      case parse_frame( <<Buffer/binary, Data/binary>> ) of
        { Frame, TailBuffer }->
          Owner ! { data, self(), Frame },
          loop( State#state{ buffer = TailBuffer } );
        TailBuffer ->
          loop( State#state{ buffer = TailBuffer } )
      end;
    {send, Owner, Frame}->
      Packet = build_frame( Frame ),
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
parse_frame(<<?START_CMD, CF, Address, CS, ?END_CHAR, Tail/binary>>) ->
  case control_sum( <<CF, Address>> ) of
    CS ->
      case parse_cf( <<CF>> ) of
        {ok, CFRec} ->
          { #frame{
            addr = Address,
            cf = CFRec,
            data = undefined
          }, Tail };
        error->
          ?LOGERROR("invalid control field ~p",[ CF ]),
          Tail
      end;
    _->
      ?LOGERROR("invalid control sum"),
      Tail
  end;

parse_frame(<<?START_DATA, LengthL:8, LengthL:8, ?START_DATA, Body/binary >> = Buffer) ->
  case Body of
    << FrameData:LengthL/binary, CS, ?END_CHAR, Tail/binary >>->
      case control_sum( FrameData ) of
        CS ->
          << CF, Address, Data/binary >> = FrameData,
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
parse_frame( Buffer )->
  Buffer.

build_frame( #frame{addr = Address, cf = CFRec, data = Data } ) when is_binary( Data )->
  Body = <<
    Address,
    (build_cf( CFRec )),
    Data/binary
  >>,
  L = size( Body ),
  CS = control_sum( Body ),

  <<?START_DATA, L:8, L:8, ?START_DATA, Body/binary, CS, ?END_CHAR >>;

build_frame( #frame{addr = Address, cf = CFRec } )->
  Body = <<
    (build_cf( CFRec )),
    Address
  >>,
  CS = control_sum( Body ),

  <<?START_CMD, Body/binary, CS, ?END_CHAR>>.

control_sum( Data )->
  control_sum( Data, 0 ).
control_sum(<<X, Rest/binary >>, Sum)->
  control_sum( Rest, Sum + X );
control_sum( <<>>, Sum )->
  Sum rem 8.


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
