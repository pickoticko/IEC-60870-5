-module(iec60870_asdu).

-export([
  parse/2,
  build/3
]).

% SQ (Structure Qualifier) bit specifies how information are addressed
-define(SQ_DISCONTINUOUS, 0).
-define(SQ_CONTINUOUS, 1).

check_sq([{IOA, _} | Rest]) ->
  check_sq(Rest, IOA).
check_sq([{IOA, _} | Rest], PrevIOA) when IOA =:= PrevIOA + 1 ->
  check_sq(Rest, IOA);
check_sq([], _) -> ?SQ_CONTINUOUS;
check_sq(_, _) -> ?SQ_DISCONTINUOUS.

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
