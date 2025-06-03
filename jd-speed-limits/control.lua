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

function find_signals(train, rail, direction)
    find_signal(train, rail, direction, get_reverse_direction(direction), true)
    find_signal(train, rail, direction, direction, false)
end

function handle_found_signal(train, start_rail_end, rail_end, signal)
    local redSpeedLimit = signal.get_signal(speed_signal, defines.wire_connector_id.circuit_red)
    local greenSpeedLimit = signal.get_signal(speed_signal, defines.wire_connector_id.circuit_green)

    local speedLimit = 0
    if redSpeedLimit > 0 and greenSpeedLimit > 0 then
        speedLimit = math.min(redSpeedLimit, greenSpeedLimit)
    elseif (redSpeedLimit > 0) then
        speedLimit = redSpeedLimit
    else
        speedLimit = greenSpeedLimit
    end

    local speed_message
    if speedLimit > 0 then
        local params = {}
        params.train = train
        params.starts = {
            {
                rail = start_rail_end.rail,
                direction = start_rail_end.direction
            }
        }
        params.goals = {rail_end}

        local pathfinder_result = game.train_manager.request_train_path(params)

        speed_message = "with speedlimit=" .. speedLimit

        local new_path_length = 0
        if pathfinder_result.found_path then
            speed_message = speed_message .. " and path was found distance=" .. pathfinder_result.total_length
        end
    else
        speed_message = "with no speedlimit"
    end

    game.print("found signal at {" .. signal.position.x .. "," .. signal.position.y .. "} " .. speed_message)
end

function register_train(train)
    local path = train.path

    if path.size < 2 then
        return
    end

    find_signals_v2(train)

    -- -- find the path's direction
    -- local rail_end
    -- if path.is_front then
    --     rail_end = train.front_end
    -- else
    --     rail_end = train.back_end
    -- end

    -- local path_direction = rail_end.direction
    -- local reverse_path_direction

    -- if path_direction == defines.rail_direction.front then
    --     reverse_path_direction = defines.rail_direction.back
    --     game.print("the path direction is front")
    -- else
    --     reverse_path_direction = defines.rail_direction.front
    --     game.print("the path direction is back")
    -- end

    -- local start_rail = rail_end.rail
    -- local start_rail_index
    -- for i = 0, path.size do
    --     if start_rail == path.rails[i] then
    --         start_rail_index = i
    --         game.print("this rail is index " .. start_rail_index)
    --         break
    --     end
    -- end

    -- find_signals(start_rail, path_direction)

    -- local segment_rail = start_rail

    -- for rail_index = start_rail_index + 1, path.size do
    --     local path_rail = path.rails[rail_index]

    --     -- Try moving forward in each connection direction to see which way the next rail is
    --     local found_rail
    --     for _, connection_direction in ipairs(rail_connection_directions) do
    --         local rail_end_copy = rail_end.make_copy()

    --         rail_end_copy.move_forward(connection_direction)
    --         if rail_end_copy.rail == path_rail then
    --             found_rail = true
    --             rail_end = rail_end_copy

    --             break
    --         end
    --     end

    --     if not found_rail then
    --         break
    --     end

    --     if not path_rail.is_rail_in_same_rail_segment_as(segment_rail) then
    --         find_signals(path_rail, rail_end.direction)
    --         segment_rail = path_rail
    --     end
    -- end

    storage.trains[train.id] = {
        train = train,
        path = train.path,
        path_length = train.path.total_distance
    }
    game.print("register train id=" .. train.id .. " path_length=" .. train.path.total_distance)
end

function find_signals_v2(train)
    local speed_limits_on_path = {}

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

    local path_direction = rail_end.direction
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
            return
        end

        -- Find the signal out of the segment (if any). If present, this signal will be on this rail end's rail
        local outSignal = rail_end.rail.get_rail_segment_signal(rail_end.direction, false)
        if outSignal then
            handle_found_signal(train, start_rail_end, rail_end, outSignal)
        end

        -- Try moving forward in each connection direction to see which way the next rail is.
        rail_index = rail_index + 1
        if rail_index >= path.size then
            return
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
            return
        end

        local inSignal = rail_end.rail.get_rail_segment_signal(get_reverse_direction(rail_end.direction), true)
        if inSignal then
            handle_found_signal(train, start_rail_end, rail_end, inSignal)
        end
    end
end

function unregister_train(train)
    if storage.trains[train.id] ~= nil then
        game.print("unregister train id=" .. train.id)
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
            if not info.train.valid then
                storage.trains[id] = nil
            else
                local infoPath = info.path

                -- Paths can actually be altered, not just replaced. Treat a change as a replacement
                if infoPath.valid and infoPath.total_distance ~= info.path_length then
                    register_train(info.train)
                end

                -- If the path has somehow become invalid before now, keep up to date
                if not info.path.valid then
                    local path = info.train.path
                    if path then
                        register_train(info.train)
                    else
                        unregister_train(info.train)
                    end
                end
            end
        end
    end
)
