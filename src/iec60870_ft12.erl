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
  start_link/2
]).

%% Function codes of unbalanced transmission from primary station
-define(RESET_REMOTE_LINK, 0).
-define(RESET_USER_PROCESS, 1).
-define(USER_DATA_CONFIRM, 3).
-define(USER_DATA_NO_REPLY, 4).
-define(EXPECTED_RESPONSE, 8).
-define(REQUEST_STATUS_LINK, 9).
-define(REQUEST_DATA_CLASS_ONE, 10).
-define(REQUEST_DATA_CLASS_TWO, 11).
-define(REMOTE_LINK_RESET, 0).

%% Function codes of unbalanced transmission from secondary station
-define(CONFIRM_ACKNOWLEDGEMENT, 0).
-define(NOT_CONFIRMED_LINK_BUSY, 1).
-define(USER_DATA, 8).
-define(USER_DATA_NOT_AVAILABLE, 9).
-define(STATUS_LINK_DEMAND, 11).
-define(LINK_SERVICE_NOT_FUNCTIONING, 14).
-define(LINK_SERVICE_NOT_IMPLEMENTED, 15).

% Each packet (APDU) starts with
-define(START_DATA, 16#68).
-define(START_CMD, 16#10).
-define(END_CHAR, 16#16).

-define(PERMITTED_CHARACTER_1, 16#E5).
-define(PERMITTED_CHARACTER_2, 16#A2).


start_link( Port, Options )->
  Self = self(),
  PID = spawn_link(fun()-> init( Self, Port, Options ) end),
  receive
    {ready, PID} -> PID;
    {'EXIT' ,PID, Reason}-> throw( Reason )
  end.

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
      clear( Port ),
      loop( State#state{ buffer = <<>> } )
  end.

clear( Port )->
  receive
    {Port, data, _Data}-> clear( Port )
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

build_frame( #frame{ data = Data } ) when is_binary( Data )->
  % TODO. Data frame
  todo;

build_frame( #frame{  } )->
  % TODO. Control frame
  todo.




parse_frame(<<
  ?START_CHAR_A,
  LengthL:8,
  LengthL:8,
  ?START_CHAR_A,
  ControlField:8,
  AddressField:8,
  LinkUserData,
  CheckSum:8,
  ?END_CHAR>>) ->
  %% TODO: Verification of checksum
  #{
    control_field => ControlField,
    address_field => AddressField,
    link_user_data => LinkUserData
  };

%% Frame with fixed length
parse_frame(<<
  ?START_CHAR_B,
  ControlField:8,
  AddressField:8,
  LinkUserData,
  CheckSum:8,
  ?END_CHAR>>) ->
  todo;

parse_frame(<<?PERMITTED_CHARACTER_1>>) -> todo;
parse_frame(<<?PERMITTED_CHARACTER_2>>) -> todo;
parse_frame(Frame) -> throw({invalid_frame, Frame}).

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

