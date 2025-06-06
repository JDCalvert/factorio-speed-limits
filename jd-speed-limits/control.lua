require("scripts.train")
require("scripts.path")

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

-- If mods configuration has changed, recalculate trains' derived values
script.on_configuration_changed(
    function()
        for _, train_info in pairs(storage.trains) do
            calculate_derived(train_info)
        end
    end
)

-- When a train is created, register it. If the train was made by merging or splitting existing trains,
-- take the lowest existing speed limit of the old trains.
script.on_event(
    defines.events.on_train_created, function(event)
        local speed_limit = nil

        speed_limit = check_existing_speed_limit(event.old_train_id_1, speed_limit)
        speed_limit = check_existing_speed_limit(event.old_train_id_2, speed_limit)

        local train_info = register_train(event.train)
        train_info.current_speed_limit = speed_limit
    end
)

-- When a train changes state to on_the_path, register the path. If it updates to any other state, unregister the path
script.on_event(
    defines.events.on_train_changed_state, function(event)
        local train = event.train
        local train_info = get_train_info(train)

        if train.state == defines.train_state.on_the_path and train.path and train.path.valid then
            register_path(train_info)
        else
            unregister_path(train_info)
        end
    end
)

script.on_event(
    defines.events.on_tick, function(event)

        -- Go through registered trains and ensure they're still valid
        for id, train_info in pairs(storage.trains) do
            local train = train_info.train
            if not train.valid then
                storage.trains[id] = nil
            else
                -- Recalculate the train's power every so often in case its fuel has changed
                if event.tick % 300 == id % 300 then
                    calculate_power(train_info)
                end

                if train_info.path_info then
                    local path = train_info.path_info.path

                    -- Paths can actually be altered, not just replaced. Treat a change as a replacement
                    if path.valid and path.total_distance ~= train_info.path_info.cached_length then
                        register_path(train_info)
                    end

                    -- If the path has somehow become invalid before now, keep up to date
                    if not path.valid then
                        path = train.path
                        if path then
                            register_path(train_info)
                        else
                            unregister_path(train_info)
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

-- Check if we need to slow the train down for speed limits
function handle_train(train_info)
    -- Ignore trains that don't have a path, including manually-driven trains
    if train_info.path_info == nil then
        return
    end

    local train = train_info.train
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
            if train_info.current_speed_limit == nil or speed_limit_info.speed_limit < train_info.current_speed_limit then
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
