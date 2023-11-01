IEC104 Protocol Application
=====
IEC is a standard for power system monitoring, control, and other related communications to automate electric power systems.
[IEC104](https://en.wikipedia.org/wiki/IEC_60870-5) is an extension of the IEC 101 protocol, including transport, network, link, and physical layer extensions to enable full network access.
This is a library for communicating with devices that use this protocol.

To **start** the application use `start_client/1`, which will return the `Client` structure, which should be used for all operations.  
To **stop** the application use `stop` and pass `Client` to it.

Interface
-----
| Function               | Arguments                         | Description  |
| :--------------------- |:--------------------------------- | :----------- |
| `send_data/4`          | Client, DataObject, Group, COT    | Send data to the station |
| `read_object_value/2`  | Client, Key                       | Read a value from the cache by key |
| `add_subscriber/3`     | Client, SubscriberPID, Arg        | Adds a subscriber, which will receive any changes on objects |
| `remove_subscriber/3`  | Client, SubscriberPID, Key        | Removes subscriber |  
| `remove_subscriber/2`  | Client, SubscriberPID             | Removes subscription of SubscriberPID entirely |  

> **Note**  
> `Arg` on `add_subscriber` is an address of the data object

Usage samples & examples
-----
Initial settings (example) to start the connection:
```erlang
ConnectionSettings = #{
connection => #{port => 2404, host => {127, 0, 0, 1}, type => '104'},
name => connection1,
coa_bytesize => 2,
org_bytesize => 1,
ioa_bytesize => 3,
t1 => 40000,
t2 => 15000,
groups => [0],
org => 0,
coa => 1,
k => 12,
w => 8
}.
```

Starting the connection:
```erlang
Client = iec104:start_client(ConnectionSettings).
```

Send object:
```erlang
iec104:send_data(Client, <Data Object>, 0, <<"non-cycle">>).
```

Read object:
```erlang
iec104:read_object_value(Client, <Information Object Address>).
```

Add subscriber:
```erlang
iec104:add_subscriber(Client, SubscriberPID, <Data Object Key>).
iec104:add_subscriber(Client, SubscriberPID, [<Information Object Address 1>, ..., <Information Object Address N>]).
```

Remove subscriber:
```erlang
iec104:remove_subscriber(Client, SubscriberPID, <Information Object Address>). % Removes subscription for a specific key
iec104:remove_subscriber(Client, SubscriberPID). % Removes subscription entirely
```
