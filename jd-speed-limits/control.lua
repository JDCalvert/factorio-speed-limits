local LOG_DEBUG = true

local speed_signal = {
    type = "virtual",
    name = "signal-speed"
}

local rail_connection_directions = {
    defines.rail_connection_direction.straight,
    defines.rail_connection_direction.left,
    defines.rail_connection_direction.right
}

function debug(str)
    if LOG_DEBUG then
        game.print(str)
    end
end

function get_reverse_direction(direction)
    if direction == defines.rail_direction.front then
        return defines.rail_direction.back
    else
        return defines.rail_direction.front
    end
end

function handle_found_signal(train_info, start_rail_end, rail_end, signal)
    local redSpeedLimit = signal.get_signal(speed_signal, defines.wire_connector_id.circuit_red)
    local greenSpeedLimit = signal.get_signal(speed_signal, defines.wire_connector_id.circuit_green)

    local speed_limit = 0
    local speed_limit_distance = 0

    if redSpeedLimit > 0 and greenSpeedLimit > 0 then
        speed_limit = math.min(redSpeedLimit, greenSpeedLimit)
    elseif (redSpeedLimit > 0) then
        speed_limit = redSpeedLimit
    else
        speed_limit = greenSpeedLimit
    end

    local speed_message
    if speed_limit > 0 then
        local params = {
            train = train_info.train,
            starts = {
                {
                    rail = start_rail_end.rail,
                    direction = start_rail_end.direction
                }
            },
            goals = {
                rail_end
            }
        }

        local pathfinder_result = game.train_manager.request_train_path(params)

        speed_message = "with speedlimit=" .. speed_limit

        local new_path_length = 0
        if pathfinder_result.found_path then
            speed_message = speed_message .. " and path was found distance=" .. pathfinder_result.total_length

            -- Insert into the speed_limits array this speed limit, and how far along the train's actual path it applies
            table.insert(
                train_info.speed_limits, {
                    speed_limit = speed_limit,
                    distance = pathfinder_result.total_length + train_info.path.travelled_distance
                }
            )
        end
    else
        speed_message = "with no speedlimit"
    end

    debug("found signal at {" .. signal.position.x .. "," .. signal.position.y .. "} " .. speed_message)
end

function register_train(train)
    local path = train.path

    if path.size < 2 then
        return
    end

    local train_info = {
        train = train,
        deceleration_rate = calculate_deceleration(train),
        path = train.path,
        path_length = train.path.total_distance,
        speed_limits = {},
        current_speed = train.speed
    }

    calculate_acceleration(train_info)

    find_signals(train_info)

    storage.trains[train.id] = train_info
    debug("register train id=" .. train.id .. " path_length=" .. train.path.total_distance)
end

function calculate_acceleration(train_info)
    local train = train_info.train

    -- Add up friction force of whole train
    local total_friction_force = 0
    for _, rolling_stock in ipairs(train.carriages) do
        total_friction_force = total_friction_force + rolling_stock.prototype.friction_force
    end

    -- Add up power of locomotives, in J/tick
    local total_forward_power = calculate_power(train.locomotives.front_movers)
    local total_backward_power = calculate_power(train.locomotives.back_movers)

    train_info.forward = {
        power = total_forward_power,
        air_resistance_multiplier = 1 - 1000 * train.front_stock.prototype.air_resistance / train.weight,
        forward_force = (total_forward_power / 1000 - total_friction_force) / train.weight
    }
    train_info.backward = {
        power = total_backward_power,
        air_resistance_multiplier = 1 - 1000 * train.back_stock.prototype.air_resistance / train.weight,
        forward_force = (total_backward_power / 1000 - total_friction_force) / train.weight
    }
end

function calculate_power(locomotives)
    local total_power = 0
    for i, locomotive in ipairs(locomotives) do
        local fuel = locomotive.burner.currently_burning
        if fuel then
            total_power = total_power + locomotive.prototype.get_max_energy_usage() *
                              (fuel.name.fuel_acceleration_multiplier +
                                  fuel.name.fuel_acceleration_multiplier_quality_bonus * fuel.quality.level)
        end
    end

    return total_power
end

function calculate_deceleration(train)
    local force
    local braking_force = 0
    for _, stock in ipairs(train.carriages) do
        braking_force = braking_force + stock.prototype.braking_force
        force = stock.force
    end

    return braking_force * force.train_braking_force_bonus / train.weight
end

function find_signals(trainInfo)
    local train = trainInfo.train
    local path = train.path

    if path.size < 2 then
        return
    end

    -- find the path's direction
    local rail_end
    if path.is_front then
        rail_end = train.front_end
    else
        rail_end = train.back_end
    end

    local rail_index = path.current

    local start_rail_end = rail_end.make_copy()

    while true do
        -- Go to the end of the segment
        rail_end.move_to_segment_end()

        -- Increment our rail index up to the rail end's position
        local is_end_of_segment_on_path = false
        for i = rail_index, path.size do
            if path.rails[i] == rail_end.rail then
                is_end_of_segment_on_path = true
                rail_index = i
                break
            end
        end

        if not is_end_of_segment_on_path then
            break
        end

        -- Find the signal out of the segment (if any). If present, this signal will be on this rail end's rail
        local outSignal = rail_end.rail.get_rail_segment_signal(rail_end.direction, false)
        if outSignal then
            handle_found_signal(trainInfo, start_rail_end, rail_end, outSignal)
        end

        -- Try moving forward in each connection direction to see which way the next rail is.
        rail_index = rail_index + 1
        if rail_index >= path.size then
            break
        end

        local next_rail = path.rails[rail_index]
        local found_next_rail = false

        for _, connection_direction in ipairs(rail_connection_directions) do
            local rail_end_copy = rail_end.make_copy()

            rail_end_copy.move_forward(connection_direction)
            if rail_end_copy.rail == next_rail then
                found_next_rail = true
                rail_end.move_forward(connection_direction)

                break
            end
        end

        if not found_next_rail then
            break
        end

        -- Find the signal into the segment from behind. If present, this signal will be on the rail end's rail
        local inSignal = rail_end.rail.get_rail_segment_signal(get_reverse_direction(rail_end.direction), true)
        if inSignal then
            handle_found_signal(trainInfo, start_rail_end, rail_end, inSignal)
        end
    end
end

function unregister_train(train)
    if storage.trains[train.id] ~= nil then
        debug("unregister train id=" .. train.id)
    end
    storage.trains[train.id] = nil
end

-- When we first start the mod, register all trains that currently have a path
script.on_init(
    function()
        storage.trains = {}

        local trains = game.train_manager.get_trains({})
        for _, train in ipairs(trains) do
            if train.state == defines.train_state.on_the_path and train.path and train.path.valid then
                register_train(train)
            end
        end
    end
)

-- When a train changes state to on_the_path, register it. If it updates to any other state, unregister
script.on_event(
    defines.events.on_train_changed_state, function(event)
        local train = event.train
        if train.state == defines.train_state.on_the_path and train.path and train.path.valid then
            register_train(train)
        else
            unregister_train(train)
        end
    end
)

script.on_event(
    defines.events.on_tick, function(event)

        -- Go through registered trains and make sure they're still valid
        for id, info in pairs(storage.trains) do
            local train = info.train
            if not train.valid then
                storage.trains[id] = nil
            else
                local infoPath = info.path

                -- Paths can actually be altered, not just replaced. Treat a change as a replacement
                if infoPath.valid and infoPath.total_distance ~= info.path_length then
                    register_train(train)
                end

                -- If the path has somehow become invalid before now, keep up to date
                if not info.path.valid then
                    local path = train.path
                    if path then
                        register_train(train)
                    else
                        unregister_train(train)
                    end
                end
            end
        end

        for _, train_info in pairs(storage.trains) do
            local train = train_info.train
            local path = train_info.path

            local train_speed_tick = math.abs(train.speed)

            local train_direction = 1
            local direction_acceleration = train_info.forward
            if train.speed < 0 then
                train_direction = -1
                direction_acceleration = train_info.backward
            end

            -- The speed next frame if we do nothing
            local expected_train_speed_tick = (train_speed_tick + direction_acceleration.forward_force) *
                                                  direction_acceleration.air_resistance_multiplier

            local requireBraking = false
            local target_speed_tick = expected_train_speed_tick

            for i, speed_limit_info in pairs(train_info.speed_limits) do
                local speed_limit_tick = speed_limit_info.speed_limit / 216 -- km/h -> m/tick

                local distance_to_speed_limit = speed_limit_info.distance - path.travelled_distance

                -- If we're approaching the speed limit, slow down the train
                if target_speed_tick > speed_limit_tick then
                    -- S = (V^2 - U^2) / 2A
                    local deceleration_distance = (train_speed_tick ^ 2 - speed_limit_tick ^ 2) /
                                                      (2 * train_info.deceleration_rate)

                    if distance_to_speed_limit < deceleration_distance + 5 then
                        requireBraking = true
                        target_speed_tick = speed_limit_tick
                    end
                end

                -- If we're past the speed limit, set the speed of the train to be the limit
                if distance_to_speed_limit <= 0 then
                    table.remove(train_info.speed_limits, i)
                    train_info.current_speed_limit = speed_limit_info.speed_limit
                end
            end

            -- If we have an existing speed limit, adhere to that as well
            if train_info.current_speed_limit ~= nil then
                local current_speed_limit_tick = train_info.current_speed_limit / 216 -- km/h -> m/tick                

                if (target_speed_tick > current_speed_limit_tick) then
                    requireBraking = true
                    target_speed_tick = current_speed_limit_tick
                end
            end

            if requireBraking then
                local new_speed_tick = math.max(train_speed_tick - train_info.deceleration_rate, target_speed_tick)

                -- Account for the game continuing to accelerate the train after we set its speed
                -- Set the speed such that the game's acceleration results in our desired speed
                local new_speed_tick = new_speed_tick / direction_acceleration.air_resistance_multiplier -
                                           direction_acceleration.forward_force

                train.speed = new_speed_tick * train_direction
            end
        end
    end
)
