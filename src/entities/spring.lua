local springDepth = -8501
local springTexture = "objects/spring/00"

local springUp = {}

springUp.name = "spring"
springUp.depth = springDepth
springUp.justification = {0.5, 1.0}
springUp.texture = springTexture
springUp.placements = {
    name = "up",
    data = {
        playerCanUse = true
    }
}

local springRight = {}

springRight.name = "wallSpringLeft"
springRight.depth = springDepth
springRight.justification = {0.5, 1.0}
springRight.texture = springTexture
springRight.rotation = math.pi / 2
springRight.placements = {
    name = "right",
    data = {
        playerCanUse = true
    }
}

function springRight.flip(room, entity, horizontal, vertical)
    if horizontal then
        entity._name = "wallSpringRight"
    end

    return horizontal
end

local springLeft = {}

springLeft.name = "wallSpringRight"
springLeft.depth = springDepth
springLeft.justification = {0.5, 1.0}
springLeft.texture = springTexture
springLeft.rotation = -math.pi / 2
springLeft.placements = {
    name = "left",
    data = {
        playerCanUse = true
    }
}

function springLeft.flip(room, entity, horizontal, vertical)
    if horizontal then
        entity._name = "wallSpringLeft"
    end

    return horizontal
end

return {
    springUp,
    springRight,
    springLeft
}