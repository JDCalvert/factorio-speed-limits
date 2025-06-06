local speed_signal = {
    type = "virtual",
    name = "signal-speed"
}

local rail_connection_directions = {
    defines.rail_connection_direction.straight,
    defines.rail_connection_direction.left,
    defines.rail_connection_direction.right
}

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

        if pathfinder_result.found_path then
            -- Insert into the speed_limits array this speed limit, and how far along the train's actual path it applies
            table.insert(
                train_info.path_info.speed_limits, {
                    speed_limit = speed_limit,
                    distance = pathfinder_result.total_length + train_info.path_info.path.travelled_distance
                }
            )
        end
    end
end

function register_train(train)
    local train_info = {
        train = train,
        current_speed_limit = nil
    }

    calculate_derived(train_info)

    storage.trains[train.id] = train_info

    return train_info
end

function calculate_derived(train_info)
    local train = train_info.train
    local force = train.front_stock.force

    -- Add up friction force of whole train
    local total_friction_force = 0
    local total_braking_force = 0
    local total_length = 0

    for _, rolling_stock in ipairs(train.carriages) do
        local prototype = rolling_stock.prototype

        total_friction_force = total_friction_force + prototype.friction_force
        total_braking_force = total_braking_force + prototype.braking_force
        total_length = total_length + prototype.joint_distance + prototype.connection_distance
    end

    -- Add up power of locomotives, in J/tick
    local total_forward_power, forward_locomotives = calculate_power(train.locomotives.front_movers)
    local total_backward_power, backward_locomotives = calculate_power(train.locomotives.back_movers)

    train_info.forward = {
        locomotives = forward_locomotives,
        air_resistance_multiplier = 1 - 1000 * train.front_stock.prototype.air_resistance / train.weight,

        power = total_forward_power,
        forward_force = (total_forward_power / 1000 - total_friction_force) / train.weight
    }
    train_info.backward = {
        locomotives = backward_locomotives,
        air_resistance_multiplier = 1 - 1000 * train.back_stock.prototype.air_resistance / train.weight,

        power = total_backward_power,
        forward_force = (total_backward_power / 1000 - total_friction_force) / train.weight
    }
    train_info.friction_force = total_friction_force
    train_info.deceleration_rate = total_braking_force * force.train_braking_force_bonus / train.weight
    train_info.length = total_length
end

function calculate_power(locomotives)
    local total_power = 0
    local locomotive_info = {}
    for i, locomotive in ipairs(locomotives) do
        local energy_usage = locomotive.prototype.get_max_energy_usage()
        locomotive_info[i] = {
            energy_usage = energy_usage,
            burner = locomotive.burner
        }

        local fuel = locomotive.burner.currently_burning
        if fuel then
            total_power = total_power + energy_usage *
                              (fuel.name.fuel_acceleration_multiplier +
                                  fuel.name.fuel_acceleration_multiplier_quality_bonus * fuel.quality.level)
        end
    end

    return total_power, locomotive_info
end

function recalculate_power(train_info)
    game.print("recalculating power for id=" .. train_info.train.id)

    local train = train_info.train

    train_info.forward.power = calculate_power(train.locomotives.front_movers)
    train_info.forward.forward_force = (train_info.forward.power / 1000 - train_info.friction_force) / train.weight

    train_info.backward.power = calculate_power(train.locomotives.back_movers)
    train_info.backward.forward_force = (train_info.backward.power / 1000 - train_info.friction_force) / train.weight

end

function register_path(train)
    local train_info = storage.trains[train.id]
    if train_info == nil then
        train_info = register_train(train)
    end

    local path = train.path

    local path_info = {
        path = path,
        cached_length = path.total_distance,
        speed_limits = {},
        pending_speed_limits = {}
    }

    train_info.path_info = path_info

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
            handle_found_signal(train_info, start_rail_end, rail_end, outSignal)
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
            handle_found_signal(train_info, start_rail_end, rail_end, inSignal)
        end
    end
end

function unregister_path(train)
    local train_info = storage.trains[train.id]
    if train_info then
        train_info.path_info = nil
    end
end

-- When we first start the mod, register all trains that currently have a path
script.on_init(
    function()
        storage.trains = {}

        local trains = game.train_manager.get_trains({})
        for _, train in ipairs(trains) do
            register_train(train)
            if train.state == defines.train_state.on_the_path and train.path and train.path.valid then
                register_path(train)
            end
        end
    end
)

script.on_configuration_changed(
    function()
        for _, train_info in pairs(storage.trains) do
            calculate_derived(train_info)
        end
    end
)

-- When a train changes state to on_the_path, register the path. If it updates to any other state, unregister the path
script.on_event(
    defines.events.on_train_changed_state, function(event)
        local train = event.train
        if train.state == defines.train_state.on_the_path and train.path and train.path.valid then
            register_path(train)
        else
            unregister_path(train)
        end
    end
)

script.on_event(
    defines.events.on_train_created, function(event)
        local speed_limit = nil

        if event.old_train_id_1 then
            local train_info = storage.trains[event.old_train_id_1]
            if train_info then
                speed_limit = train_info.current_speed_limit
            end
        end

        if event.old_train_id_2 then
            local train_info = storage.trains[event.old_train_id_2]
            if train_info and train_info.current_speed_limit and
                (speed_limit == nil or speed_limit > train_info.current_speed_limit) then
                speed_limit = train_info.current_speed_limit
            end
        end

        local train_info = register_train(event.train)
        train_info.current_speed_limit = speed_limit

        game.print("train created id=" .. event.train.id .. " with speed_limit=" .. (speed_limit or "nil"))
    end
)

script.on_event(
    defines.events.on_tick, function(event)

        -- Go through registered trains and make sure they're still valid
        for id, train_info in pairs(storage.trains) do
            local train = train_info.train
            if not train.valid then
                storage.trains[id] = nil
            else
                -- Recalculate the train's power every so often in case its fuel has changed
                if event.tick % 300 == id % 300 then
                    recalculate_power(train_info)
                end

                if train_info.path_info then
                    local path = train_info.path_info.path

                    -- Paths can actually be altered, not just replaced. Treat a change as a replacement
                    if path.valid and path.total_distance ~= train_info.path_info.cached_length then
                        register_path(train)
                    end

                    -- If the path has somehow become invalid before now, keep up to date
                    if not path.valid then
                        path = train.path
                        if path then
                            register_path(train)
                        else
                            unregister_path(train)
                        end
                    end
                end
            end
        end

        for _, train_info in pairs(storage.trains) do
            handle_train(train_info)
        end
    end
)

function handle_train(train_info)
    local train = train_info.train

    -- Ignore speed limits in manual mode
    if train.manual_mode then
        return
    end

    local path_info = train_info.path_info

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

    if train_info.path_info ~= nil then
        for i, speed_limit_info in pairs(path_info.speed_limits) do
            local speed_limit_tick = speed_limit_info.speed_limit / 216 -- km/h -> m/tick

            local distance_to_speed_limit = speed_limit_info.distance - path_info.path.travelled_distance

            -- Once we've already started decelerating towards a new speed limit, don't keep checking
            -- if we need to decelerate
            if speed_limit_info.approaching then
                requireBraking = true
                target_speed_tick = speed_limit_tick
            else
                -- If we're approaching the speed limit, slow down the train
                if target_speed_tick > speed_limit_tick then
                    -- S = (V^2 - U^2) / 2A
                    local deceleration_distance = (train_speed_tick ^ 2 - speed_limit_tick ^ 2) /
                                                      (2 * train_info.deceleration_rate)

                    if distance_to_speed_limit < deceleration_distance + 5 then
                        requireBraking = true
                        target_speed_tick = speed_limit_tick
                        speed_limit_info.approaching = true
                    end
                end
            end

            -- If we're past the speed limit, set the speed of the train to be the limit
            if distance_to_speed_limit <= 0 then
                if train_info.current_speed_limit == nil or speed_limit_info.speed_limit <
                    train_info.current_speed_limit then
                    path_info.pending_speed_limits = {}
                    train_info.current_speed_limit = speed_limit_info.speed_limit
                else
                    -- Remove any pending speed limits higher than this one
                    for i, pending_speed_limit_info in pairs(path_info.pending_speed_limits) do
                        if pending_speed_limit_info.speed_limit > speed_limit_info.speed_limit then
                            table.remove(path_info.pending_speed_limits, i)
                        end
                    end

                    -- Add this as a pending speed limit
                    table.insert(path_info.pending_speed_limits, speed_limit_info)
                end

                table.remove(path_info.speed_limits, i)
            end
        end

        for i, pending_speed_limit_info in pairs(path_info.pending_speed_limits) do
            local speed_limit_tick = pending_speed_limit_info.speed_limit / 216 -- km/h -> m/tick

            local distance_past_speed_limit = path_info.path.travelled_distance - pending_speed_limit_info.distance
            if distance_past_speed_limit > train_info.length then
                table.remove(path_info.pending_speed_limits, i)
                train_info.current_speed_limit = pending_speed_limit_info.speed_limit
            end
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

        if direction_acceleration.power > 0 then
            local energy_usage = (train.weight *
                                     (new_speed_tick / direction_acceleration.air_resistance_multiplier -
                                         train_speed_tick) + train_info.friction_force) * 1000
            energy_usage = math.max(energy_usage, 0)

            local energy_use_proportion = energy_usage / direction_acceleration.power

            -- Go through each locomotive and give back the energy that the game will use, and take away the actual energy usage
            for _, locomotive in ipairs(direction_acceleration.locomotives) do
                locomotive.burner.remaining_burning_fuel = locomotive.burner.remaining_burning_fuel +
                                                               (1 - energy_use_proportion) * locomotive.energy_usage
            end

            -- The game will continue to accelerate the train after we set its speed
            -- Set the speed such that the game's acceleration results in our desired speed
            new_speed_tick = new_speed_tick / direction_acceleration.air_resistance_multiplier -
                                 direction_acceleration.forward_force
        end

        train.speed = new_speed_tick * train_direction
    end
end
