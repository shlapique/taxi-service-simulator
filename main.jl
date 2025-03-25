using TOML
config = TOML.parsefile("config.toml")

using ConcurrentSim
using ResumableFunctions
using Random
using Distributions
using JSON
using Base.Threads: atomic_cas!
using NearestNeighbors


mutable struct Point
    x::Float64
    y::Float64
end

mutable struct Taxi
    id::Int
    state::Symbol # :idle | :en_route | :busy | :done
    location::Point
    pickup_location::Union{Point, Nothing}
    dropoff_location::Union{Point, Nothing}
    trip_counter::Int
    locked::Threads.Atomic{Int} # 0 - free, 1 - occupied
end

mutable struct Client
    id::Int
    location::Point
end

mutable struct Order
    id::Int
    client::Client
    taxi::Union{Taxi, Nothing}
    status::Symbol # :pending | :processing | :completed | :declined
    pickup_location::Point
    dropoff_location::Point
	timestamp::Float64
end

order_id_counter = 0
client_id_counter = 0

# available taxis
const taxis = [] 
global kdtree::Union{Nothing, KDTree} = nothing


function upd_kdtree!()
    taxi_positions = hcat([t.location.x for t in taxis], [t.location.y for t in taxis])'
    global kdtree = KDTree(taxi_positions)
end

function random_point()
    return Point(rand(Uniform(0, config["MAP_SIZE"][1])), rand(Uniform(0, config["MAP_SIZE"][2])))
end


function point_to_dict(point::Point)
    return Dict("x" => point.x, "y" => point.y)
end

function log_event(event_type::String, time::Float64, details::Dict)
    if event_type == "taxi_location_update"
        event = Dict("event_type" => event_type, "timestamp" => round(time, digits=3), "details" => details)
        open(config["TELEM_LOG_FILE"], "a") do file
            println(file, JSON.json(event))
        end
    elseif event_type == "client_online"
        event = Dict("event_type" => event_type, "timestamp" => round(time, digits=3), "details" => details)
        open(config["CLIENT_FILE"], "a") do file
            println(file, JSON.json(event))
        end
    elseif event_type == "ride_accept"
        event = Dict("event_type" => event_type, "timestamp" => round(time, digits=3), "details" => details)
        open(config["RIDE_ACCEPT_FILE"], "a") do file
            println(file, JSON.json(event))
        end
    elseif event_type == "ride_pending"
        event = Dict("event_type" => event_type, "timestamp" => round(time, digits=3), "details" => details)
        open(config["RIDE_PEND_FILE"], "a") do file
            println(file, JSON.json(event))
        end
    elseif event_type == "ride_request"
        event = Dict("event_type" => event_type, "timestamp" => round(time, digits=3), "details" => details)
        open(config["RIDE_REQ_FILE"], "a") do file
            println(file, JSON.json(event))
        end
    elseif event_type == "taxi_state_change"
        event = Dict("event_type" => event_type, "timestamp" => round(time, digits=3), "details" => details)
        open(config["TAXI_STATE_FILE"], "a") do file
            println(file, JSON.json(event))
        end
    else
        event = Dict("event_type" => event_type, "timestamp" => round(time, digits=3), "details" => details)
        open(config["EVENT_LOG_FILE"], "a") do file
            println(file, JSON.json(event))
        end
    end
end


function find_nearest_idle_taxi(p::Point)::Union{Taxi, Nothing}
    nearest_indices, distancies = knn(kdtree, [p.x, p.y], config["NEAREST_TAXI_POOL"], true)

    for attempt in 1:config["MAX_ATTEMPTS"]
        for idx in nearest_indices
            t = taxis[idx]

            # trying to capture...
            if atomic_cas!(t.locked, 0, 1) == 0
                return t
            end
        end
    end
    return nothing
end

function move_towards(t::Taxi, target::Point, speed::Float64)
    dx, dy = target.x - t.location.x, target.y - t.location.y
    distance = hypot(dx, dy)
    if distance <= speed
        t.location = target
    else
        t.location.x += speed * dx / distance
        t.location.y += speed * dy / distance
    end
end

@resumable function get_unique_order_id(env::Simulation, id_resource::Resource)::Int
    global order_id_counter
    @yield request(id_resource)
    order_id_counter += 1
    unique_id = order_id_counter
    @yield unlock(id_resource)
    return unique_id
end

@resumable function get_unique_client_id(env::Simulation, id_resource::Resource)::Int
    global client_id_counter
    @yield request(id_resource)
    client_id_counter += 1
    unique_id = client_id_counter
    @yield unlock(id_resource)
    return unique_id
end

@resumable function agent(env::Simulation, id_resource::Resource, a)
    while true
        new_client_time = rand(Exponential(1 / config["LAMBDA"]))
        @yield timeout(env, new_client_time)

        location = random_point() # client location
        client_id = @yield @process get_unique_client_id(env, id_resource)
        @process client(env, id_resource, Client(client_id, location))
    end
end

@resumable function client(env::Simulation, id_resource::Resource, c::Client)
    log_event("client_online", now(env), Dict("id" => c.id,
                                               "location" => point_to_dict(c.location)))

    # creating order...
    order_id = @yield @process get_unique_order_id(env, id_resource)

    # TODO
    dest = random_point() # desired location

    ord = @yield @process orderp(env, Order(order_id, c, nothing, :pending, c.location, dest, now(env)))
end

@resumable function orderp(env::Simulation, ord::Order)
    log_event("ride_request", now(env), Dict("id" => ord.id,
                                             "client_id" => ord.client.id,
                                             "pickup_location" => point_to_dict(ord.pickup_location),
                                             "dropoff_location" => point_to_dict(ord.dropoff_location)))
    while true
        nearest_taxi = find_nearest_idle_taxi(ord.pickup_location)
        if isnothing(nearest_taxi)
            log_event("ride_pending", now(env), Dict("id" => ord.id,
                                                     "client_id" => ord.client.id,
                                                     "status" => ord.status,
                                                     "pickup_location" => point_to_dict(ord.pickup_location),
                                                     "dropoff_location" => point_to_dict(ord.dropoff_location)))
            @yield timeout(env, 10)
        else
            ord.taxi = nearest_taxi
            nearest_taxi.pickup_location = ord.pickup_location
            nearest_taxi.dropoff_location = ord.dropoff_location
            nearest_taxi.state = :en_route
            ord.status = :processing
            log_event("ride_accept", now(env), Dict("id" => ord.id,
                                                    "client_id" => ord.client.id,
                                                    "taxi_id" => ord.taxi.id,
                                                    "status" => ord.status,
                                                    "pickup_location" => point_to_dict(ord.pickup_location),
                                                    "dropoff_location" => point_to_dict(ord.dropoff_location)))
            break
        end
    end
    while nearest_taxi.state != :done
        @yield timeout(env, 1)
    end
    ord.status = :completed
    nearest_taxi.trip_counter += 1
    log_event("trip_end", now(env), Dict("id" => ord.id,
                                         "client_id" => ord.client.id,
                                         "taxi_id" => ord.taxi.id,
                                         "status" => ord.status,
                                         "pickup_location" => point_to_dict(ord.pickup_location),
                                         "dropoff_location" => point_to_dict(ord.dropoff_location)))
    nearest_taxi.state = :idle
    atomic_cas!(nearest_taxi.locked, 1, 0)
end

@resumable function taxi(env::Simulation, t::Taxi)
    interrupted = false
    while true
        log_event("taxi_location_update", now(env), Dict("id" => t.id,
                                                           "state" => t.state,
                                                           "location" => point_to_dict(t.location)))
        if t.state == :idle 
            @yield timeout(env, 10)
            t.location.x+= randn() * 10
            t.location.y += randn() * 10
        elseif t.state == :en_route
            log_event("taxi_state_change", now(env), Dict("id" => t.id,
                                                          "state" => t.state))

            while (t.location != t.pickup_location)
                move_towards(t, t.pickup_location, config["TAXI_SPEED"])
                log_event("taxi_location_update", now(env), Dict("id" => t.id,
                                                                 "state" => t.state,
                                                                 "location" => point_to_dict(t.location)))
                @yield timeout(env, 5.0)
            end
            t.state = :busy
        elseif t.state == :busy 
            log_event("taxi_state_change", now(env), Dict("id" => t.id,
                                                          "state" => t.state))
            while (t.location != t.dropoff_location)
                move_towards(t, t.dropoff_location, config["TAXI_SPEED"])
                log_event("taxi_location_update", now(env), Dict("id" => t.id,
                                                                 "state" => t.state,
                                                                 "location" => point_to_dict(t.location)))
                @yield timeout(env, 5.0)
            end
            t.state = :done
        elseif t.state == :done
            @yield timeout(env, 2)
        end
    end
end

function start_sim(env::Simulation, id_resource::Resource)
    # run taxis
    for i in 1:config["NUM_TAXIS"]
        t = Taxi(i, :idle, random_point(), nothing, nothing, 0, Threads.Atomic{Int}(0))
        push!(taxis, t)
        @process taxi(env, t)
    end

    upd_kdtree!()

    # run agents
    for i in 1:config["NUM_AGENTS"]
        @process agent(env, id_resource, i)
    end
end

function taxi_service_sim()
    env = Simulation()
    id_resource = Resource(env, 1)
    start_sim(env, id_resource)
    run(env, config["SIM_TIME"])
end

taxi_service_sim()
