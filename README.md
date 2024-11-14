# Taxi service simulator
## set the env

```bash
julia --project=jenv
```
```julia
]instantiate
```

## edit the config file (if you like) `config.toml`

## run

```julia
include("main.jl")
```

# Description of the taxi service simulator

## Taxi

There are always $N$ taxis on the map. They change their `state` depending on receiving an order.

* `state = 'idle'`

  * NOW: moves in random steps from the last order point (or the starting point of the workday &mdash; $t_{simulation} = 0$).

  * TODO: moves according to the *two-dimensional random walk* model (needs many steps to really go far). Or [*Wiener process*](https://en.wikipedia.org/wiki/Random_walk).

* `state = 'en_route'`

  * NOW: Moves to the client in a straight trajectory.

  * TODO: consider complex movement with a function reducing the vector to the client.

* `state = 'busy'`

  * NOW: Moves in a straight trajectory to `dropoff_location`.

  * TODO: Complex movement to the point.

* `state = 'done'`

  * NOW: The order is completed. Waiting for approval from the **Order** process. (that is, actually, to return it to the `'idle'` state)

## Agent

**Agent** &mdash; <u>intentionally</u> complicated order generation process. This is an asynchronous process that creates a *Client* process every $t \sim P(\lambda)$. And this is in `while true...`

Agents are needed for a more realistic appearance of orders on the map. Specifically from the perspective of `timestamp`.

***That is, the number of Clients is actually limited only by `SIM_TIME`.***

## Client

NOW: A process that generates the *Order* process and that's it.

TODO: Complete the implementation of order cancellation by the client with some probability. Such cancellation will only work while the taxi is in `state = 'en_route'`, that is, on the way to the client.

## Order

The process of handling an order from the client.

What it does:

1. finds a taxi in the taxi with `state = 'idle'`.

2. **(!)** changes the taxi's state `state` in the following sequence:

`'idle'` → `'en_route'` → `'busy'` → **(waits until the taxi's state becomes `'done'`)** → `'idle'`.

As soon as the taxi reaches the `'idle'` state, the process **ends**.

**END.**

All this depends on the location of the taxi driver, their actions (see above in [Taxi](#taxi))

# Diagram

Approximate principle of operation

```mermaid
flowchart TD

    %% Main simulation process
    subgraph Simulation[Simulation Start]
        Start[Start Simulation] --> Initialize[Initialize Taxis and Agents]
    end

    %% Taxi processes
    subgraph Taxi_Process["Taxi Process"]
        TaxiIdle[Taxi: idle state] -->|waiting for client| TaxiUpdate[Location update]
        TaxiUpdate --> TaxiIdle
        TaxiIdle -->|accepting order| TaxiEnRoute[Taxi: en_route state]
        TaxiEnRoute --> TaxiToClient[Taxi moving to client]
        TaxiToClient --> TaxiBusy[Taxi: busy state]
        TaxiBusy --> TaxiToDestination[Taxi moving to destination]
        TaxiToDestination --> TaxiComplete[Trip complete]
        TaxiComplete --> TaxiIdle
    end

    %% Agent processes
    subgraph Agent_Process["Agent Process"]
        AgentLoop[Endless client generation loop] --> GenerateClient[Generate new client]
        GenerateClient --> StartClient[Start Client Process]
    end

    %% Client and Order processes
    subgraph Client_Order_Process[Client and Order Processes]
        StartClient --> CreateOrder[Create new Order]
        CreateOrder --> SearchTaxi[Search for idle Taxi]
        SearchTaxi -->|taxi found| OrderAccepted[Order: taxi accepted]
        SearchTaxi -->|taxi not found| OrderPending[Order: waiting]
        OrderAccepted --> TaxiEnRoute
        OrderPending --> SearchTaxi
        OrderAccepted --> OrderComplete[Order and Client complete]
        OrderComplete --> ClientDisappears[Client disappears]
    end

    %% Parallel processes
    Initialize -->|create NUM_TAXIS taxis| Taxi_Process
    Initialize -->|create NUM_AGENTS agents| Agent_Process
    AgentLoop --> Client_Order_Process
    OrderComplete --> TaxiComplete
```
