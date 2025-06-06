local rail_connection_directions = {
    defines.rail_connection_direction.straight,
    defines.rail_connection_direction.left,
    defines.rail_connection_direction.right
}

local speed_signal = {
    type = "virtual",
    name = "signal-speed"
}

function unregister_path(train_info)
    train_info.path_info = nil
end

function register_path(train_info)
    local train = train_info.train
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

function get_reverse_direction(direction)
    if direction == defines.rail_direction.front then
        return defines.rail_direction.back
    else
        return defines.rail_direction.front
    end
end
