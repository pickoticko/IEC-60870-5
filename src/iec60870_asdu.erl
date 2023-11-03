%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-module(iec60870_asdu).
-include("asdu.hrl").

-export([
  parse/2,
  build/2
]).

%% +--------------------------------------------------------------+
%% |                           Macros                             |
%% +--------------------------------------------------------------+

% SQ (Structure Qualifier) bit specifies how information are addressed
-define(SQ_DISCONTINUOUS, 0).
-define(SQ_CONTINUOUS, 1).

%% +--------------------------------------------------------------+
%% |                             API                              |
%% +--------------------------------------------------------------+

parse(APDU, #{
  ioa_bits = IOABitSize,
  org_bits = ORGBitSize,
  coa_bits = COABitSize
}) ->
  {DUI, ObjectsBinary} = parse_dui(COABitSize, ORGBitSize, APDU),
  Objects = split_objects(DUI, IOABitSize, ObjectsBinary),
  #{
    type => Type,
    t    => T,
    pn   => PN,
    cot  => COT,
    org  => ORG,
    coa  => COA
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
  org = ORG,
  coa = COA,
  objects = DataObjects
}, #{
  ioa_bits = IOABitSize,
  org_bits = ORGBitSize,
  coa_bits = COABitSize
}) ->
  NumberOfObjects = length(DataObjects),
  SQ =
    if
      NumberOfObjects > 1 -> check_sq(DataObjects);
      true -> ?SQ_DISCONTINUOUS
    end,
  InformationObjects = create_information_objects(SQ, Type, DataObjects, IOABitSize),
  <<Type:8             /integer,
    SQ:1               /integer,
    NumberOfObjects:7  /integer,
    0:1, 0:1, COT:6    /little-integer,
    ORG:ORGBitSize     /little-integer,
    COA:COABitSize     /little-integer,
    InformationObjects /binary>>.

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