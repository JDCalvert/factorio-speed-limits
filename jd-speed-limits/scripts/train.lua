function get_train_info(train)
    local train_info = storage.trains[train.id]
    if train_info == nil then
        train_info = register_train(train)
    end

    return train_info
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

-- Calculate useful values for the train that won't change over time
function calculate_derived(train_info)
    local train = train_info.train
    local force = train.front_stock.force

    train_info.friction_force = 0
    train_info.length = 0

    local total_braking_force = 0

    for _, rolling_stock in ipairs(train.carriages) do
        local prototype = rolling_stock.prototype

        train_info.friction_force = train_info.friction_force + prototype.friction_force
        total_braking_force = total_braking_force + prototype.braking_force
        train_info.length = train_info.length + prototype.joint_distance + prototype.connection_distance
    end

    train_info.deceleration_rate = total_braking_force * force.train_braking_force_bonus / train.weight

    train_info.forward = {
        locomotives = build_locomotives(train.locomotives.front_movers),
        air_resistance_multiplier = 1 - 1000 * train.front_stock.prototype.air_resistance / train.weight
    }
    train_info.backward = {
        locomotives = build_locomotives(train.locomotives.back_movers),
        air_resistance_multiplier = 1 - 1000 * train.back_stock.prototype.air_resistance / train.weight
    }

    calculate_power(train_info)
end

function build_locomotives(locomotives)
    local locomotive_info = {}
    for i, locomotive in ipairs(locomotives) do
        local energy_usage = locomotive.prototype.get_max_energy_usage()
        locomotive_info[i] = {
            energy_usage = energy_usage,
            burner = locomotive.burner
        }
    end

    return locomotive_info
end

function calculate_power(train_info)
    calculate_direction_power(train_info, "forward")
    calculate_direction_power(train_info, "backward")
end

function calculate_direction_power(train_info, direction)
    local direction_info = train_info[direction]

    local total_power = 0
    for i, locomotive in ipairs(direction_info.locomotives) do
        local fuel = locomotive.burner.currently_burning
        if fuel then
            total_power = total_power + locomotive.energy_usage *
                              (fuel.name.fuel_acceleration_multiplier +
                                  fuel.name.fuel_acceleration_multiplier_quality_bonus * fuel.quality.level)
        end
    end

    direction_info.power = total_power
    direction_info.forward_force = (total_power / 1000 - train_info.friction_force) / train_info.train.weight
end

function check_existing_speed_limit(train_id, current_speed_limit)
    if train_id == nil then
        return current_speed_limit
    end

    local train_info = storage.trains[train_id]
    if train_info then
        local train_speed_limit = train_info.current_speed_limit
        if train_speed_limit ~= nil and (current_speed_limit == nil or train_speed_limit < current_speed_limit) then
            return train_speed_limit
        end
    end

    return current_speed_limit
end