%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-module(iec60870_asdu).
-include("asdu.hrl").

-export([
  get_settings/1,
  parse/2,
  build/2
]).

%% +--------------------------------------------------------------+
%% |                           Macros                             |
%% +--------------------------------------------------------------+

% SQ (Structure Qualifier) bit specifies how information are addressed
-define(SQ_DISCONTINUOUS, 0).
-define(SQ_CONTINUOUS, 1).

-define(MAX_PACKET_BYTE_SIZE, 255).

get_settings( #{
  coa_size := COASize,
  org_size := ORGSize,
  ioa_size := IOASize
} = Settings )->
  Settings#{
    coa_size => COASize * 8,
    org_size => ORGSize * 8,
    ioa_size => IOASize * 8
  }.

%% +--------------------------------------------------------------+
%% |                             API                              |
%% +--------------------------------------------------------------+

parse(ASDU, #{
  ioa_bits := IOABitSize,
  org_bits := ORGBitSize,
  coa_bits := COABitSize
}) ->
  {DUI, ObjectsBinary} = parse_dui(COABitSize, ORGBitSize, ASDU),
  Objects = split_objects(DUI, IOABitSize, ObjectsBinary),
  #{
    type := Type,
    t    := T,
    pn   := PN,
    cot  := COT,
    org  := ORG,
    coa  := COA
  } = DUI,
  ParsedObjects =
    [begin
       {Address, iec60870_type:parse_information_element(Type, Object)}
     end || {Address, Object} <- Objects],
  #asdu{
    type = Type,
    pn = PN,
    t = T,
    cot = COT,
    org = ORG,
    coa = COA,
    objects = ParsedObjects
  }.

build(#asdu{
  type = Type,
  cot = COT,
  objects = DataObjects
}, #{
  org := ORG,
  coa := COA,
  ioa_bits := IOABitSize,
  org_bits := ORGBitSize,
  coa_bits := COABitSize
}) ->
  NumberOfObjects = length(DataObjects),
  SQ =
    if
      NumberOfObjects > 1 -> check_sq(DataObjects);
      true -> ?SQ_DISCONTINUOUS
    end,
  HeaderSize = (
      4 %% Transport Constant Cost
    + 3 %% ASDU Constant Cost
    + ORGBitSize * 8
    + COABitSize * 8
    + SQ * IOABitSize * 8),
  [{_IOA, Value} | _] = DataObjects,
  ElementSize =
    size(iec60870_type:create_information_element(Type, Value)) + (abs(SQ - 1) * IOABitSize * 8),
  AvailableSize = ?MAX_PACKET_BYTE_SIZE - HeaderSize,
  MaxObjectsNumber = AvailableSize div ElementSize,
  InformationObjectsList = split(DataObjects, MaxObjectsNumber),
  [begin
    <<Type:8            /integer,
      SQ:1              /integer,
      NumberOfObjects:7 /integer,
      0:1, 0:1, COT:6   /little-integer,
      ORG:ORGBitSize    /little-integer,
      COA:COABitSize    /little-integer,
      (create_information_objects(SQ, Type, InformationObjects, IOABitSize))/binary>>
   end || InformationObjects <- InformationObjectsList].

%% +--------------------------------------------------------------+
%% |                 Internal helper functions                    |
%% +--------------------------------------------------------------+

split_objects(#{sq := ?SQ_CONTINUOUS, no := NumberOfObjects}, IOASize, ObjectsBin) ->
  <<Start:IOASize/little-integer, Sequence/binary>> = ObjectsBin,
  ObjectSize = round(iec60870_lib:bytes_to_bits(size(Sequence) / NumberOfObjects)),
  ObjectsList = [<<Object:ObjectSize>> || <<Object:ObjectSize>> <= Sequence],
  lists:zip(lists:seq(Start, Start + NumberOfObjects - 1), ObjectsList);

split_objects(#{sq := ?SQ_DISCONTINUOUS, no := NumberOfObjects}, IOASize, ObjectsBin) ->
  ObjectSize = round((iec60870_lib:bytes_to_bits(size(ObjectsBin)) - IOASize * NumberOfObjects) / NumberOfObjects),
  [{Address, <<Object:ObjectSize>>} || <<Address:IOASize/little-integer, Object:ObjectSize>> <= ObjectsBin].

create_information_objects(_SQ = ?SQ_CONTINUOUS, Type, DataObjects, IOABitSize) ->
  InformationObjectsList =
    [iec60870_type:create_information_element(Type, Value) || {_, Value} <- DataObjects],
  InformationObjects =
    <<<<Value/binary>> || Value <- InformationObjectsList>>,
  {StartAddress, _} = hd(DataObjects),
  <<
    StartAddress:IOABitSize /little-integer,
    InformationObjects      /binary
  >>;

create_information_objects(_SQ = ?SQ_DISCONTINUOUS, Type, DataObjects, IOABitSize) ->
  InformationObjectsList =
    [{IOA, iec60870_type:create_information_element(Type, Value)} || {IOA, Value} <- DataObjects],
  <<<<Address:IOABitSize/little-integer, Value/binary>> || {Address, Value} <- InformationObjectsList>>.

%% Checks addresses (IOAs) for a sequence
check_sq([{IOA, _} | Rest]) ->
  check_sq(Rest, IOA).
check_sq([{IOA, _} | Rest], PrevIOA) when IOA =:= PrevIOA + 1 ->
  check_sq(Rest, IOA);
check_sq([], _) -> ?SQ_CONTINUOUS;
check_sq(_, _) -> ?SQ_DISCONTINUOUS.

%% Parses Data Unit Identifier (DUI)
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

split(DataObjects, MaxNumber) when length( DataObjects ) > MaxNumber->
  { Head, Tail } = lists:split(MaxNumber, DataObjects),
  [Head | split(Tail, MaxNumber)];

split(DataObjects, _MaxSize)->
  DataObjects.