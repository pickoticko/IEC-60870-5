
-ifndef(iec60870_balanced).
-define(iec60870_balanced, 1).

%% Function codes from PRIMARY to SECONDARY
-define(RESET_REMOTE_LINK, 0).
-define(RESET_USER_PROCESS, 1).
-define(LINK_TEST, 2).
-define(USER_DATA_CONFIRM, 3).
-define(USER_DATA_NO_REPLY, 4).
-define(ACCESS_DEMAND, 8).
-define(REQUEST_STATUS_LINK, 9).

%% Function codes from SECONDARY to PRIMARY
-define(ACKNOWLEDGE, 0).
-define(NACK_LINK_BUSY, 1).
-define(USER_DATA, 8).
-define(STATUS_LINK_ACCESS_DEMAND, 11).

-endif.