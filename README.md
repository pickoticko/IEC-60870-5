# IEC104 Protocol Application

## Description
**IEC-60870-5 (IEC101 & IEC104)** is a standard for power system monitoring, control, and other related communications to automate electric power systems.  
This library implements communication with devices that use this protocol.

## Getting started
### Executing
You will need to [install rebar3](https://rebar3.org/) to work with the project: 
1. Clone the repo  
```
git clone https://github.com/pickoticko/IEC-60870-5.git
```
3. Compile the project  
```
rebar3 compile
```
5. Launch the project  
```
rebar3 shell
```
### Adding to the existing project
Add dependency to your ```rebar.config```  
```
{iec60870, {git, "https://github.com/pickoticko/IEC-60870-5.git", {branch, "master"}}}
```  
Then don't forget to add the library to relx release (if needed)
```
{iec60870, load}
```

## Interface & Usage
| Function               | Arguments                                      | Returns    | Description  |
| :--------------------- |:---------------------------------------------- | :--------- | :----------- |
| **`start_client/1`**   | Settings                                       | Client     | Starts the client |
| **`start_server/1`**   | Settings                                       | Server     | Starts the server |
| **`stop/1`**           | Client / Server                                | OK         | Stops a server or a client |
| `subscribe/2`          | Client / Server, SubscriberPID                 | OK         | Subscribes to all existing addresses |
| `subscribe/3`          | Client / Server, SubscriberPID, Address / List | OK         | Subscribes to an address or a list of addresses |
| `unsubscribe/2`        | Client / Server, SubscriberPID                 | OK         | Removes subscription from SubscriberPID entirely |  
| `unsubscribe/3`        | Client / Server, SubscriberPID, Address        | OK         | Removes subscription from the given address |  
| `read/1`               | Client / Server                                | List       | Reads all existing addresses |
| `read/2`               | Client / Server, Address                       | Object     | Read a value from the cache by an address |
| `write/2`              | Client / Server, Address, Value                | OK         | Writes a value to the cache |

## Authors
Contributors names and contact info:  
- Alikhan Tokenov, alikhantokenov@gmail.com  
- Vozzhenikov Roman, vzroman@gmail.com  
