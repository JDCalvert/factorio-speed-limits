function trivial_smoke(smoke_data)
    local smoke = data.raw["trivial-smoke"]["train-smoke"]
    local new_smoke = table.deepcopy(smoke)
    for k, v in pairs(smoke_data) do
        new_smoke[k] = v
    end

    return new_smoke
end

function particle(particle_data)
    return {
        type = "optimized-particle",
        name = particle_data.name,
        offset_deviation = {
            1,
            1
        },
        life_time = 2,
        regular_trigger_effect = particle_data.smoke_effect,
        regular_trigger_effect_frequency = 5
    }
end

-- Disable the locomotive's normal smoke - we'll make our own
local locomotive = data.raw["locomotive"]["locomotive"]
if locomotive then
    locomotive["energy_source"]["smoke"] = {}
end

-- Create smoke that, when we generate it ourselves, looks the same as
-- the normal train smoke
local working_train_smoke = trivial_smoke {
    name = "working-train-smoke",
    movement_slow_down_factor = 0.96
}

-- Create 
local idle_train_smoke = trivial_smoke {
    name = "idle-train-smoke",
    movement_slow_down_factor = 0.96,
    color = {
        0.1,
        0.1,
        0.1,
        0.1
    }
}

local working_train_smoke_particle = particle {
    name = "working-train-smoke-particle",
    smoke_effect = {
        type = "create-trivial-smoke",
        smoke_name = "working-train-smoke",
        initial_height = 0.8,
        probability = 0.9,
        starting_frame = 0,
        starting_frame_deviation = 60,
        speed = {
            x = 0,
            y = -0.2
        },
        speed_multiplier = 1,
        speed_multiplier_deviation = 0.5
    }
}

local idle_train_smoke_particle = particle {
    name = "idle-train-smoke-particle",
    smoke_effect = {
        type = "create-trivial-smoke",
        smoke_name = "idle-train-smoke",
        initial_height = 0.8,
        probability = 0.9,
        starting_frame = 0,
        starting_frame_deviation = 60,
        speed = {
            x = 0,
            y = -0.1
        },
        speed_multiplier = 1,
        speed_multiplier_deviation = 0.5
    }
}

data:extend{
    working_train_smoke,
    idle_train_smoke,
    working_train_smoke_particle,
    idle_train_smoke_particle
}
