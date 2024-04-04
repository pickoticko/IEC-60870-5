# IEC104 Protocol Application

## Description
**IEC-60870-5 (IEC101 & IEC104)** is a standard for power system monitoring, control, and other related communications to automate electric power systems.  
This library implements communication with devices that use this protocol.

## Getting started
Used Erlang OTP version: 25 [erts-13.2]
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

## Interface
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

### Usage
To start the connection, both ```start_client``` and ```start_server``` require a map passed with these arguments. 
**IEC101 Client / Server:** 
```erlang
#{
	name => iec101_client_example, % Unique name of the connection
	type => '101', % Type of the connection
	groups => [],  % Group requests
	coa_size => 2, % Common Address Size (bytes)
	org_size => 1, % Originator Address Size (bytes)
	ioa_size => 3, % Information Object Size (bytes)
	coa => 1,      % Common Address
	org => 0,      % Originator Address
	connection => #{
		port => "/dev/ttyUSB0",   % Serial port name
		balanced => false,        % Balanced - true, unbalanced - false
		port_options => #{      
			baudrate => 9600, % Communication speed
			parity => 1,      % Parity bit: 0 - None, 1 - Even, 2 - Odd
			stopbits => 1,    % Number of stop bits 
			bytesize => 8     % Number of data bits
		},
		address => 1,      % Data link address
		address_size => 2, % Data link address size
		timeout => 5000,   % Connect timeout
		attempts => 99     % Attempts to connect
	}
},
```
**IEC104 Client:**
```erlang
#{
	name => iec104_client_example, % Unique name of the connection
	type => '104', % Type of the connection
	groups => [],  % Group requests
	coa_size => 2, % Common Address Size (bytes)
	org_size => 1, % Originator Address Size (bytes)
	ioa_size => 3, % Information Object Size (bytes)
	coa => 1,      % Common Address
	org => 0,      % Originator Address
	connection => #{
		host => {127, 0, 0, 1}, % Server IP address
		port => 2404, % Listening port (default: 2404, reserved: 2405)
		t1 => 30000,  % T1 packets timeout
		t2 => 5000,   % T2 acknowledge timeout
		t3 => 15000,  % T3 idle (testfr packets) timeout
		k => 12,      % Maximum transmitted APDUs
		w => 8        % Maximum received APDUs
	}
},
```
**IEC104 Server:** All settings are identical to the client, except without the ```host``` field.

## Authors
Contributors names and contact info:  
- Alikhan Tokenov, alikhantokenov@gmail.com  
- Vozzhenikov Roman, vzroman@gmail.com  
