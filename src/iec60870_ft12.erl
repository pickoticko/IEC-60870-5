%% +--------------------------------------------------------------+
%% | Copyright (c) 2023, Faceplate LTD. All Rights Reserved.      |
%% | Author: Tokenov Alikhan, @alikhantokenov@gmail.com           |
%% +--------------------------------------------------------------+

-module(iec60870_ft12).
-behaviour(gen_statem).

-export([
  parse_frame/1,
  parse_control_field/2
]).

-include("iec60870.hrl").

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
-define(START_CHAR_A, 16#68).
-define(START_CHAR_B, 16#10).
-define(END_CHAR, 16#16).

-define(PERMITTED_CHARACTER_1, 16#E5).
-define(PERMITTED_CHARACTER_2, 16#A2).

%% Frame with variable length
parse_frame(<<
  ?START_CHAR_A,
  LengthL,
  LengthL,
  ?START_CHAR_A,
  ControlField,
  AddressField,
  LinkUserData,
  CheckSum,
  ?END_CHAR>>) ->
  todo;

%% Frame with fixed length
parse_frame(<<
  ?START_CHAR_B,
  ControlField,
  AddressField,
  LinkUserData,
  CheckSum,
  ?END_CHAR>>) ->
  todo;

parse_frame(<<?PERMITTED_CHARACTER_1>>) -> todo;
parse_frame(<<?PERMITTED_CHARACTER_2>>) -> todo;
parse_frame(Frame) -> throw({invalid_frame, Frame}).

parse_control_field(primary, <<
  RES:1,
  1:1, % PRM
  FCB:1,
  FCV:1,
  FunctionCode:4
>>) ->
  #{
    res => RES,
    fcb => FCB,
    fcv => FCV,
    function => FunctionCode
  };

parse_control_field(secondary, <<
  RES:1,
  0:1, % PRM
  ACD:1,
  DFC:1,
  FunctionCode:4
>>) ->
  #{
    res => RES,
    acd => ACD,
    dfc => DFC,
    function => FunctionCode
  };

parse_control_field(_, Data) -> throw({invalid_control_field, Data}).


