local summitGems = {}

summitGems.name = "summitgem"
summitGems.depth = 10100

function summitGems.texture(room, entity)
    local index = entity.gem or 0

    return string.format("collectables/summitgems/%s/gem00", index)
end

return summitGems