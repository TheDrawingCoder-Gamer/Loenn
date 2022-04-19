local configs = require("configs")
local loadedState = require("loaded_state")
local fileLocations = require("file_locations")
local utils = require("utils")
local logging = require("logging")
local lfs = require("lib.lfs_ffi")
local history = require("history")

local backups = {}

local timestampFormat = "%Y-%m-%d %H-%M-%S"
local timestampPattern = "(%d%d%d%d)-(%d%d)-(%d%d) (%d%d)-(%d%d)-(%d%d)"

local function saveCallback(filename)
    logging.debug(string.format("Created map backup to '%s'", filename))
end

function backups.getBackupMapName(map)
    map = map or loadedState.map

    if map then
        local humanizedFilename = utils.filename(utils.stripExtension(loadedState.filename))
        local mapName = map.package or humanizedFilename

        return mapName
    end
end

-- Folder to put the backup in
function backups.getBackupPath(map)
    local backupsPath = fileLocations.getBackupPath()
    local mapName = backups.getBackupMapName(map)

    if mapName then
        return utils.joinpath(backupsPath, mapName)
    end
end

local function findOldestBackup(fileInformations)
    local oldestTimestamp = math.huge
    local oldestFilename

    for filename, info in pairs(fileInformations) do
        if info.created < oldestTimestamp then
            oldestTimestamp = info.created
            oldestFilename = filename
        end
    end

    return oldestFilename
end

-- TODO - Implement more modes, fallback to "oldest" for now
local function findBackupToPrune(fileInformations)
    local pruningMode = configs.backups.backupMode

    return findOldestBackup(fileInformations)
end

local function getTimeFromFilename(filename)
    local year, month, day, hour, minute, second = string.match(filename, timestampPattern)

    return os.time({year=year, month=month, day=day, hour=hour, min=minute, sec=second})
end

function backups.cleanupBackups(map)
    local backupFilenames = backups.getMapBackups(map)
    local backupCount = #backupFilenames
    local maximumBackups = configs.backups.maximumFiles

    if backupCount > maximumBackups then
        local fileInformations = {}

        for _, filename in ipairs(backupFilenames) do
            fileInformations[filename] = {
                filename = filename,
                created = getTimeFromFilename(filename)
            }
        end

        while backupCount > maximumBackups do
            local deleteFilename = findBackupToPrune(fileInformations)

            if not deleteFilename then
                break
            end

            local success = utils.remove(deleteFilename)

            if not success then
                break
            end

            fileInformations[deleteFilename] = nil
            backupCount -= 1
        end
    end
end

function backups.getMapBackups(map)
    local filenames = {}
    local backupPath = backups.getBackupPath(map)

    if backupPath then
        -- utils.getFilenames only works on mounted paths
        for filename in lfs.dir(backupPath) do
            if utils.fileExtension(filename) == "bin" then
                local fullPath = utils.joinpath(backupPath, filename)

                table.insert(filenames, fullPath)
            end
        end
    end

    return filenames
end

function backups.createBackup(map)
    local backupPath = backups.getBackupPath(map)

    if backupPath then
        local timestamp = os.date(timestampFormat, os.time())
        local filename = utils.joinpath(backupPath, timestamp .. ".bin")

        loadedState.saveFile(filename, saveCallback)
        backups.cleanupBackups(map)
    end
end

function backups.createBackupDevice()
    local device = {
        _type = "device",
        _enabled = true
    }

    device.deltaTimeAcc = 0
    device.backupRate = configs.backups.backupRate

    -- Always keep the device running, but skip the backup step if backups are disabled
    -- Prevent hammering the config for values, update every time we would make a backup
    function device.update(dt)
        device.deltaTimeAcc += dt

        if device.deltaTimeAcc >= device.backupRate then
            device.deltaTimeAcc -= device.backupRate
            device.backupRate = configs.backups.backupRate

            if configs.backups.enabled and history.madeChanges then
                backups.createBackup()
            end
        end
    end

    return device
end

return backups