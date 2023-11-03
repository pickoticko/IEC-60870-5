IEC104 Protocol Application
=====

Description
-----
IEC is a standard for power system monitoring, control, and other related communications to automate electric power systems.
[IEC104](https://en.wikipedia.org/wiki/IEC_60870-5) is an extension of the IEC 101 protocol, including transport, network, link, and physical layer extensions to enable full network access.
This is a library for communicating with devices that use this protocol.

Interface & Usage
-----  

| Function               | Arguments                                      | Returns    | Description  |
| :--------------------- |:---------------------------------------------- | :--------- | :----------- |
| **`start_client/1`**   | Settings                                       | **Client** | **Starts the client** |
| **`start_server/1`**   | Settings                                       | **Server** | **Starts the server** |
| **`stop/1`**           | Client / Server                                | OK         | **Stops a server or a client** |
| `subscribe/2`          | Client / Server, SubscriberPID                 | OK         | Subscribes to all existing addresses |
| `subscribe/3`          | Client / Server, SubscriberPID, Address / List | OK         | Subscribes to an address or a list of addresses |
| `unsubscribe/2`        | Client / Server, SubscriberPID                 | OK         | Removes subscription from SubscriberPID entirely |  
| `unsubscribe/3`        | Client / Server, SubscriberPID, Address        | OK         | Removes subscription from the given address |  
| `read/1`               | Client / Server                                | List       | Reads all existing addresses |
| `read/2`               | Client / Server, Address                       | Object     | Read a value from the cache by an address |
| `write/2`              | Client / Server, Address, Value                | OK         | Writes a value to the cache |

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
Client = iec60870:start_client(ConnectionSettings).
Server = iec60870:start_server(ConnectionSettings).
```

Read object:
```erlang
iec60870:read(Client, <Information Object Address>).
iec60870:read(Client).
```

Add subscriber:
```erlang
iec60870:subscribe(Client, SubscriberPID, <Address>).
iec60870:subscribe(Client, SubscriberPID).
```

Remove subscriber:
```erlang
iec60870:unsubscribe(Client, SubscriberPID, <Address>). 
iec60870:unsubscribe(Client, SubscriberPID). 
```
