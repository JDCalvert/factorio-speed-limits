require("scripts.train")
require("scripts.path")

local idle_smoke = {
    type = "idle",
    intensity = 5
}

-- When we first start the mod, register all trains that currently have a path
script.on_init(
    function()
        storage.trains = {}

        local trains = game.train_manager.get_trains({})
        for _, train in ipairs(trains) do
            local train_info = register_train(train)
            if train.path and train.path.valid then
                register_path(train_info)
            end
        end
    end
)

-- If mods configuration has changed, recalculate trains' derived values
script.on_configuration_changed(
    function()
        for _, train_info in pairs(storage.trains) do
            train_info.current_speed = math.abs(train_info.train.speed)
            train_info.smoke = idle_smoke

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

        if train.path and train.path.valid and (train_info.path_info == nil or not train_info.path_info.path.valid) then
            register_path(train_info)
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
            create_smoke(train_info)
        end
    end
)

-- Check if we need to slow the train down for speed limits
function handle_train(train_info)
    local train = train_info.train

    local train_speed_tick = math.abs(train.speed)

    local train_direction = 1
    local direction = train_info.forward
    if train.speed < 0 then
        train_direction = -1
        direction = train_info.backward
    end

    -- Default smoke to idle
    train_info.smoke = idle_smoke

    local previous_speed = train_info.current_speed
    train_info.current_speed = train_speed_tick

    -- For trains in manual mode, calculate their smoke based on their
    if train.manual_mode then
        if train_speed_tick > previous_speed then
            train_info.smoke = {
                type = "working",
                intensity = 100
            }
        elseif train_speed_tick == previous_speed and train_speed_tick > 0 then
            train_info.smoke = {
                type = "working",
                intensity = 100 * calculate_power_proportion(train_info, direction, previous_speed, train_speed_tick)
            }
        end

        return
    end

    -- Ignore trains that don't have a path
    if train_info.path_info == nil then
        return
    end

    local path_info = train_info.path_info

    -- Calculate if we've gone past a speed limit sign.
    for i, speed_limit_info in pairs(path_info.speed_limits) do
        local distance_to_speed_limit = speed_limit_info.distance - path_info.path.travelled_distance
        -- If we're past the speed limit, set the speed of the train to be the limit
        if distance_to_speed_limit <= 0 then
            -- If the new speed limit is less than our current one, set it straight away, and clear any pending speed limits
            -- If the new speed limit is greather than our current one, set it as a pending speed limit which will take effect
            -- once the whole train has passed it.
            if train_info.current_speed_limit == nil or speed_limit_info.speed_limit < train_info.current_speed_limit then
                path_info.pending_speed_limits = {}
                train_info.current_speed_limit = speed_limit_info.speed_limit
            else
                -- Remove any pending speed limits higher than this one
                for j, pending_speed_limit_info in pairs(path_info.pending_speed_limits) do
                    if pending_speed_limit_info.speed_limit > speed_limit_info.speed_limit then
                        table.remove(path_info.pending_speed_limits, j)
                    end
                end

                -- Add this as a pending speed limit
                table.insert(path_info.pending_speed_limits, speed_limit_info)
            end

            table.remove(path_info.speed_limits, i)
        end
    end

    -- Calculate if the entire train has gone past a pending speed limit
    for i, pending_speed_limit_info in pairs(path_info.pending_speed_limits) do
        local speed_limit_tick = pending_speed_limit_info.speed_limit / 216 -- km/h -> m/tick

        local distance_past_speed_limit = path_info.path.travelled_distance - pending_speed_limit_info.distance
        if distance_past_speed_limit >= train_info.length - 2 then
            table.remove(path_info.pending_speed_limits, i)
            train_info.current_speed_limit = pending_speed_limit_info.speed_limit
        end
    end

    -- If we're not "on the path" (normal driving) then don't alter the train's speed
    if train.state ~= defines.train_state.on_the_path then
        return
    end

    -- For train on the path, assume they're working at full power until we find otherwise
    train_info.smoke = {
        type = "working",
        intensity = 100
    }

    local train_speed_tick = math.abs(train.speed)

    local train_direction = 1
    local direction = train_info.forward
    if train.speed < 0 then
        train_direction = -1
        direction = train_info.backward
    end

    -- The speed next frame if we do nothing
    local expected_train_speed_tick = (train_speed_tick + direction.forward_force) * direction.air_resistance_multiplier

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

        if direction.power > 0 then
            local power_use = calculate_power_proportion(train_info, direction, train_speed_tick, new_speed_tick)

            -- Go through each locomotive and give back the energy that the game will use, and take away the actual energy usage
            for _, locomotive in ipairs(direction.locomotives) do
                locomotive.burner.remaining_burning_fuel = locomotive.burner.remaining_burning_fuel + (1 - power_use) *
                                                               locomotive.energy_usage
            end

            if power_use > 0 then
                train_info.smoke = {
                    type = "working",
                    intensity = 100 * power_use
                }
            else
                train_info.smoke = idle_smoke
            end

            -- The game will continue to accelerate the train after we set its speed
            -- Set the speed such that the game's acceleration results in our desired speed
            new_speed_tick = new_speed_tick / direction.air_resistance_multiplier - direction.forward_force
        end

        train.speed = new_speed_tick * train_direction
    else
        -- We're not slowing the train down, but it could be slowing down of its own accord
        if train_speed_tick < previous_speed then
            train_info.smoke = idle_smoke
        elseif previous_speed == train_speed_tick then
            train_info.smoke = {
                type = "working",
                intensity = 100 * calculate_power_proportion(train_info, direction, train_speed_tick, train_speed_tick)
            }
        end
    end
end

-- Calculate how much of the train's power we're using to accelerate or maintain speed
function calculate_power_proportion(train_info, direction, old_speed, new_speed)
    local energy_usage = (train_info.train.weight * (new_speed / direction.air_resistance_multiplier - old_speed) +
                             train_info.friction_force) * 1000
    energy_usage = math.max(energy_usage, 0)

    return energy_usage / direction.power
end

function create_smoke(train_info)
    -- The engine is effectively off if the train is manual, stopped, with no passenger
    if train_info.train.manual_mode and train_info.current_speed == 0 and #train_info.train.passengers == 0 then
        return
    end

    local smoke = {
        type = train_info.smoke.type .. "-train-smoke-particle",
        intensity = math.max(train_info.smoke.intensity, 10)
    }

    local direction = train_info.forward
    local other_direction = train_info.backward
    if train_info.train.speed < 0 then
        direction = train_info.backward
        other_direction = train_info.forward
    end

    -- The locomotives going forward should all put out their % power
    for _, locomotive in ipairs(direction.locomotives) do
        locomotive_create_smoke(locomotive.locomotive, smoke)
    end

    -- If locomotive is a multiple unit (from Multiple Unit Train Control) then show the locomotive working, otherwise idle
    for _, locomotive in ipairs(other_direction.locomotives) do
        if locomotive.is_multiple_unit then
            locomotive_create_smoke(locomotive.locomotive, smoke)
        else
            locomotive_create_smoke(
                locomotive.locomotive, {
                    type = "idle-train-smoke-particle",
                    intensity = 5
                }
            )
        end
    end
end

function locomotive_create_smoke(locomotive, smoke)
    if locomotive.burner.currently_burning == nil then
        return
    end

    local rand = math.random(100)
    if rand <= smoke.intensity then
        locomotive.surface.create_particle(
            {
                name = smoke.type,
                position = locomotive.position,
                movement = {
                    0,
                    0
                },
                height = 0.5 + math.random(),
                vertical_speed = 0,
                frame_speed = 1
            }
        )
    end
end
