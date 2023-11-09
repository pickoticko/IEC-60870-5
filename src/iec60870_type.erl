%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+
-module(iec60870_type).

-include("iec60870.hrl").
-include("asdu.hrl").

-export([
  parse_information_element/2,
  create_information_element/2
]).

parse_information_element(?C_CS_NA_1, CP56) ->
  parse_cp56(CP56);

parse_information_element(?C_IC_NA_1, <<GroupID:8>>) ->
  GroupID - ?COT_GROUP_MIN;

parse_information_element(?C_CI_NA_1, <<GroupCounterID:8>>) ->
  GroupCounterID - ?COT_GROUP_COUNTER_MIN;

parse_information_element(?M_EI_NA_1, <<COI:8>>) ->
  #{value => 0, qds => COI};

parse_information_element(?M_SP_NA_1, <<QDS:7, Value:1>>) ->
  #{value => Value, qds => QDS};

parse_information_element(?M_DP_NA_1, <<QDS:6, Value:2>>) ->
  #{value => Value, qds => QDS};

parse_information_element(?M_ME_NA_1, <<V1:8, V2:8, QDS:8>>) ->
  <<S:1, UnsignedValue:15/integer>> = <<V2, V1>>,
  Value =
    if
      S =:= 1 -> -UnsignedValue;
      true -> UnsignedValue
    end,
  #{value => Value, qds => QDS};

parse_information_element(?M_ME_NB_1, <<V1:8, V2:8, QDS:8>>) ->
  <<S:1, UnsignedValue:15/integer>> = <<V2, V1>>,
  % TODO. The value must be scaled
  Value =
    if
      S =:= 1 -> -UnsignedValue;
      true -> UnsignedValue
    end,
  #{value => Value, qds => QDS};

parse_information_element(?M_ME_NC_1, <<Value:32/little-float, QDS:8>>) ->
  #{value => Value, qds => QDS};

parse_information_element(?M_SP_TB_1, <<QDS:7, Value:1, Timestamp/binary>>) ->
  #{value => Value, qds => QDS, ts => parse_cp56(Timestamp)};

parse_information_element(?M_DP_TB_1, <<QDS:6, Value:2, Timestamp/binary>>) ->
  #{value => Value, qds => QDS, ts => parse_cp56(Timestamp)};

parse_information_element(?M_ME_TF_1, <<Value:32/little-float, QDS:8, Timestamp/binary>>) ->
  #{value => Value, qds => QDS, ts => parse_cp56(Timestamp)};

parse_information_element(_Type, _Value) ->
  % TODO: throw({invalid_type_or_value, Type, Value}).
  ignore_this.

%% +--------------------------------------------------------------+

create_information_element(?C_CS_NA_1, CP56) ->
  get_cp56(CP56);

create_information_element(?C_IC_NA_1, GroupID) ->
  <<(GroupID + ?COT_GROUP_MIN)>>;

create_information_element(?C_CI_NA_1, GroupCounterID) ->
  <<(GroupCounterID + ?COT_GROUP_COUNTER_MIN)>>;

create_information_element(?M_SP_NA_1, #{
  value := Value,
  qds := QDS
}) ->
  <<QDS:7, (round(Value)):1/integer>>;

create_information_element(?M_DP_NA_1, #{
  value := Value,
  qds := QDS
}) ->
  <<QDS:6/little-integer, (round(Value)):2/integer>>;

create_information_element(?M_ME_NA_1, #{
  value := Value,
  qds := QDS
}) ->
  <<M1:8, M2:8>> = <<(round(Value)):16/integer>>,
  <<M2, M1, QDS:8/little-integer>>;

create_information_element(?M_ME_NB_1, #{
  value := Value,
  qds := QDS
}) ->
  % TODO. The value must be unscaled
  <<M1:8, M2:8>> = <<(round(Value)):16/integer>>,
  <<M2, M1, QDS:8/little-integer>>;

create_information_element(?M_ME_NC_1, #{
  value := Value,
  qds := QDS
}) ->
  <<M1:8, M2:8, M3:8, M4:8>> = <<(1.0 * Value):32/float>>,
  <<M4, M3, M2, M1, QDS:8/little-integer>>;

create_information_element(?M_SP_TB_1, #{
  value := Value,
  qds := QDS,
  ts := Timestamp
}) ->
  CP56 =
    case Timestamp of
      undefined -> get_cp56(0);
      _ -> get_cp56(Timestamp)
    end,
  <<QDS:7/little-integer, (round(Value)):1/integer, CP56/binary>>;

create_information_element(?M_DP_TB_1, #{
  value := Value,
  qds := QDS,
  ts := Timestamp
}) ->
  CP56 =
    case Timestamp of
      undefined -> get_cp56(0);
      _ -> get_cp56(Timestamp)
    end,
  <<QDS:6/little-integer, (round(Value)):2/integer, CP56/binary>>;

create_information_element(?M_ME_TF_1, #{
  value := Value,
  qds := QDS,
  ts := Timestamp
}) ->
  CP56 =
    case Timestamp of
      undefined -> get_cp56(0);
      _ -> get_cp56(Timestamp)
    end,
  <<M1:8, M2:8, M3:8, M4:8>> = <<(1.0 * Value):32/float>>,
  <<M4, M3, M2, M1, QDS:8/little-integer, CP56/binary>>;

create_information_element(OtherType, _) -> throw({unsupported_type, OtherType}).

parse_cp56(CP) ->
  <<
    Milliseconds:16/little-integer,
    _R1:2,
    Min:6  /integer,
    _R2:3,
    H:5    /integer,
    _WD:3  /integer,
    D:5    /integer,
    _R3:4,
    MN:4   /integer,
    _res4:1,
    Y:7    /integer
  >> = CP,
  try
    [DT | _] = calendar:local_time_to_universal_time_dst({
      {Y + 2000, MN, D},
      {H, Min, (Milliseconds div 1000)}
    }),
    calendar:datetime_to_gregorian_seconds(DT) * 1000 - 62167219200000
  catch
    _:Error ->
      ?LOGERROR("parse_cp56 error: ~p, Timestamp: ~p", [CP, Error]),
      none
  end.

get_cp56(Value) ->
  try
    Gs = (Value + 62167219200000) div 1000,
    {{Y, MN, D}, {H, Min, S}} = calendar:gregorian_seconds_to_datetime(Gs),
    Ms = S * 1000 + (Value + 62167219200000) - Gs * 1000,
    WD = calendar:day_of_the_week(Y, MN, D),
    YCP56 = Y - 2000,
    <<Ms:16/little-integer, 16#00:2, Min:6/integer, 16#00:3, H:5/integer, WD:3/integer, D:5/integer, 16#00:4, MN:4/integer, 16#00:1, YCP56:7/integer>>
  catch
    _:Error ->
      ?LOGERROR("get_cp56 error: ~p, Timestamp: ~p", [Value, Error]),
      none
  end.