local viewportHandler = require("viewport_handler")
local tasks = require("utils.tasks")
local mapcoder = require("mapcoder")
local celesteRender = require("celeste_render")
local sceneHandler = require("scene_handler")
local filesystem = require("utils.filesystem")
local fileLocations = require("file_locations")
local utils = require("utils")
local history = require("history")
local persistence = require("persistence")
local configs = require("configs")
local meta = require("meta")
local saveSanitizers = require("save_sanitizers")

local sideStruct = require("structs.side")

local state = {}

state.currentSaves = {}
state.pendingSaves = {}

local function getWindowTitle(side)
    local name = sideStruct.getMapName(side)

    return string.format("%s - %s", meta.title, name)
end

-- Add to persistence most recent files
-- Ordered from most recently opened -> oldest, with no duplicates
local function addToRecentFiles(filename)
    if not filename or filename == "" then
        return
    end

    local maxEntries = configs.editor.recentFilesEntryLimit
    local recentFiles = persistence.recentFiles or {}

    for i = #recentFiles, 1, -1 do
        if recentFiles[i] == filename then
            table.remove(recentFiles, i)
        end
    end

    table.insert(recentFiles, 1, filename)

    for i = maxEntries + 1, #recentFiles do
        recentFiles[i] = nil
    end

    persistence.recentFiles = recentFiles
end

local function updateSideState(side, roomName, filename, eventName)
    eventName = eventName or "editorMapLoaded"

    celesteRender.invalidateRoomCache()
    celesteRender.clearBatchingTasks()

    state.filename = filename
    state.side = side
    state.map = state.side.map

    celesteRender.loadCustomTilesetAutotiler(state)

    history.reset()

    local initialRoom = state.map and state.map.rooms[1]

    if roomName then
        local roomByName = state.getRoomByName(roomName)

        if roomByName then
            initialRoom = roomByName
        end
    end

    state.selectItem(initialRoom)

    persistence.lastLoadedFilename = filename
    persistence.lastSelectedRoomName = state.selectedItem and state.selectedItem.name

    addToRecentFiles(filename)

    love.window.setTitle(getWindowTitle(side))

    sceneHandler.changeScene("Editor")
    sceneHandler.sendEvent(eventName, filename)
end

-- Calls before save functions
function state.defaultBeforeSaveCallback(filename, state)
    return saveSanitizers.beforeSave(filename, state)
end

-- Updates state filename and flags history with no changes
function state.defaultAfterSaveCallback(filename, state)
    state.filename = filename
    history.madeChanges = false

    return saveSanitizers.afterSave(filename, state)
end

function state.defaultVerifyErrorCallback(filename)
    sceneHandler.sendEvent("editorMapVerificationFailed", filename)

    filesystem.remove(filename)
end

-- Check that the target file can be loaded again
function state.verifyFile(filename, successCallback, errorCallback)
    errorCallback = errorCallback or state.defaultVerifyErrorCallback
    tasks.newTask(
        (-> filename and mapcoder.decodeFile(filename)),
        function(binTask)
            if binTask.success and binTask.result then
                tasks.newTask(
                    (-> sideStruct.decodeTaskable(binTask.result)),
                    function(decodeTask)
                        if decodeTask.success then
                            successCallback()
                        end
                    end
                )

            else
                errorCallback(filename)
            end
        end
    )
end

function state.getTemporaryFilename(filename)
    return filename .. ".saving"
end

function state.loadFile(filename, roomName)
    if not filename then
        return
    end

    if history.madeChanges then
        sceneHandler.sendEvent("editorLoadWithChanges", state.filename, filename)

        return
    end

    -- Check for temporary save exists
    local temporaryFilename = state.getTemporaryFilename(filename)
    local targetInfo = filesystem.pathAttributes(filename)
    local temporaryInfo = filesystem.pathAttributes(temporaryFilename)

    if temporaryInfo and not targetInfo then
        -- Temporary exists but not our actual target, move temporary as actual
        filesystem.rename(temporaryFilename, filename)

    elseif temporaryInfo and targetInfo then
        -- Both exists, delete temporary
        filesystem.remove(temporaryFilename)
    end

    sceneHandler.changeScene("Loading")

    tasks.newTask(
        (-> filename and mapcoder.decodeFile(filename)),
        function(binTask)
            if binTask.success and binTask.result then
                tasks.newTask(
                    (-> sideStruct.decodeTaskable(binTask.result)),
                    function(decodeTask)
                        updateSideState(decodeTask.result, roomName, filename, "editorMapLoaded")
                    end
                )

            else
                sceneHandler.changeScene("Editor")

                sceneHandler.sendEvent("editorMapLoadFailed", filename)
            end
        end
    )
end

-- Prevent overlapping saves, add data to reschedule after current save is finished
-- Any new save while we already have a queued save is considered obsolete, only the latest save matters
local function queueDelayedSave(...)
    local arguments = {...}
    local filename = arguments[1]

    state.pendingSaves[filename] = arguments
end

local function resumeQueuedSave(filename)
    if state.pendingSaves[filename] then
        state.saveFile(unpack(state.pendingSaves[filename]))

        state.pendingSaves[filename] = nil
    end
end

local function mapSaveSuccess(filename)
    state.currentSaves[filename] = nil

    sceneHandler.sendEvent("editorMapSaved", filename)
    resumeQueuedSave(filename)
end

local function mapSaveFailed(filename)
    state.currentSaves[filename] = nil

    sceneHandler.sendEvent("editorMapSaveFailed", filename)
    resumeQueuedSave(filename)
end

function state.saveFile(filename, afterSaveCallback, beforeSaveCallback, addExtIfMissing, verifyMap)
    if filename and state.side then
        if addExtIfMissing ~= false and filesystem.fileExtension(filename) ~= "bin" then
            filename ..= ".bin"
        end

        -- Check if we are already saving, queue save and delay this
        if state.currentSaves[filename] then
            queueDelayedSave(filename, afterSaveCallback, beforeSaveCallback, addExtIfMissing, verifyMap)

            return
        end

        state.currentSaves[filename] = true

        if afterSaveCallback ~= false then
            afterSaveCallback = afterSaveCallback or state.defaultAfterSaveCallback
        end

        if beforeSaveCallback ~= false then
            beforeSaveCallback = beforeSaveCallback or state.defaultBeforeSaveCallback

            local callbackResult = beforeSaveCallback(filename, state)

            if not callbackResult then
                sceneHandler.sendEvent("editorMapSaveInterrupted", filename)

                return false
            end
        end

        local temporaryFilename = state.getTemporaryFilename(filename)

        -- Don't need temporary filename if we don't verify the map
        if verifyMap == false then
            temporaryFilename = filename
        end

        filesystem.mkpath(filesystem.dirname(temporaryFilename))

        tasks.newTask(
            (-> sideStruct.encodeTaskable(state.side)),
            function(encodeTask)
                if encodeTask.success and encodeTask.result then
                    tasks.newTask(
                        (-> mapcoder.encodeFile(temporaryFilename, encodeTask.result)),
                        function(binTask)
                            if binTask.success then
                                if verifyMap ~= false then
                                    state.verifyFile(temporaryFilename, function()
                                        filesystem.remove(filename)
                                        filesystem.rename(temporaryFilename, filename)

                                        if afterSaveCallback then
                                            afterSaveCallback(filename, state)
                                        end

                                        mapSaveSuccess(filename)
                                    end)

                                else
                                    if afterSaveCallback then
                                        afterSaveCallback(filename, state)
                                    end

                                    mapSaveSuccess(filename)
                                end

                            else
                                mapSaveFailed(filename)
                            end
                        end
                    )

                else
                    mapSaveFailed(filename)
                end
            end
        )
    end
end

function state.selectItem(item, add)
    local itemType = utils.typeof(item)
    local previousItem = state.selectedItem
    local previousItemType = state.selectedItemType

    if itemType == "room" then
        persistence.lastSelectedRoomName = item.name
    end

    if add then
        if state.selectedItemType ~= "table" then
            state.selectedItem = {
                [state.selectedItem] = state.selectedItemType
            }

            state.selectedItemType = "table"
        end

        if not state.selectedItem[item] then
            state.selectedItem[item] = itemType

            sceneHandler.sendEvent("editorMapTargetChanged", state.selectedItem, state.selectedItemType, previousItem, previousItemType, add)
        end

    else
        state.selectedItem = item
        state.selectedItemType = itemType

        sceneHandler.sendEvent("editorMapTargetChanged", state.selectedItem, state.selectedItemType, previousItem, previousItemType, add)
    end
end

function state.getSelectedRoom()
    return state.selectedItemType == "room" and state.selectedItem or false
end

function state.getSelectedFiller()
    return state.selectedItemType == "filler" and state.selectedItem or false
end

function state.getSelectedItem()
    return state.selectedItem, state.selectedItemType
end

function state.isItemSelected(item)
    if state.selectedItem == item then
        return true

    elseif state.selectedItemType == "table" then
        return not not state.selectedItemType[item]
    end

    return false
end

function state.openMap()
    local targetDirectory = fileLocations.getCelesteDir()

    if state.filename and filesystem.isFile(state.filename) then
        targetDirectory = filesystem.dirname(state.filename)
    end

    filesystem.openDialog(targetDirectory, "bin", state.loadFile)
end

function state.newMap()
    if history.madeChanges then
        sceneHandler.sendEvent("editorNewMapWithChanges")

        return
    end

    local newSide = sideStruct.decode({})

    updateSideState(newSide, nil, nil, "editorMapNew")
end

function state.saveAsCurrentMap(afterSaveCallback, beforeSaveCallback, addExtIfMissing)
    if state.side then
        filesystem.saveDialog(state.filename, "bin", function(filename)
            state.saveFile(filename, afterSaveCallback, beforeSaveCallback, addExtIfMissing)
        end)
    end
end

function state.saveCurrentMap(afterSaveCallback, beforeSaveCallback, addExtIfMissing)
    if state.side then
        if state.filename then
            state.saveFile(state.filename, afterSaveCallback, beforeSaveCallback, addExtIfMissing)

        else
            state.saveAsCurrentMap(afterSaveCallback, beforeSaveCallback, addExtIfMissing)
        end
    end
end

function state.getRoomByName(name)
    local rooms = state.map and state.map.rooms or {}
    local nameWithLvl = "lvl_" .. name

    for i, room in ipairs(rooms) do
        if room.name == name or room.name == nameWithLvl then
            return room, i
        end
    end
end

function state.initFromPersistence()
    if persistence.onlyShowDependedOnMods ~= nil then
        state.onlyShowDependedOnMods = persistence.onlyShowDependedOnMods
    end
end

function state.getLayerVisible(layer)
    local info = state.layerInformation[layer]

    if info then
        if info.visible == nil then
            return true
        end

        return info.visible
    end

    return true
end

function state.setLayerVisible(layer, visible, silent)
    local rooms = state.map and state.map.rooms or {}
    local info = state.layerInformation[layer]

    if not info then
        info = {}
        state.layerInformation[layer] = info
    end

    info.visible = visible

    if silent ~= false then
        -- Clear target canvas and complete cache for all rooms
        celesteRender.invalidateRoomCache(nil, {"canvas", "complete"})

        -- Redraw any visible rooms
        local selectedItem, selectedItemType = state.getSelectedItem()

        celesteRender.clearBatchingTasks()
        celesteRender.forceRedrawVisibleRooms(rooms, state, selectedItem, selectedItemType)
    end
end

function state.setShowDependendedOnMods(value)
    state.onlyShowDependedOnMods = value
    persistence.onlyShowDependedOnMods = value

    -- Send event to notify changes in shown dependencies
    sceneHandler.sendEvent("editorShownDependenciesChanged", value)
end

-- The currently loaded map
state.map = nil

-- The currently selected item (room or filler)
state.selectedItem = nil
state.selectedItemType = nil
state.selectedRooms = {}

-- The viewport for the map renderer
state.viewport = viewportHandler.viewport

-- Rendering information about layers
state.layerInformation = {}

-- Hide content that is not in Everest.yaml
state.onlyShowDependedOnMods = false

return state