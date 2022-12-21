-- TODO - Should work without Everest.yaml
-- TODO - Makeit possible to update versions

local ui = require("ui")
local uiElements = require("ui.elements")
local uiUtils = require("ui.utils")

local loadedState = require("loaded_state")
local languageRegistry = require("language_registry")
local utils = require("utils")
local form = require("ui.forms.form")
local configs = require("configs")
local yaml = require("lib.yaml")

local mods = require("mods")
local dependencyEditor = require("ui.dependency_editor")
local dependencyFinder = require("dependencies")

local listWidgets = require("ui.widgets.lists")
local collapsableWidget = require("ui.widgets.collapsable")
local widgetUtils = require("ui.widgets.utils")
local gridElement = require("ui.widgets.grid")

local dependencyWindow = {}

local activeWindows = {}
local windowPreviousX = 0
local windowPreviousY = 0

local dependencyWindowGroup = uiElements.group({}):with({

})

local function prepareMetadataForSaving(metadata, newDependencies)
    local newMetadata = utils.deepcopy(metadata)

    -- Remove editor specific information
    for k, v in pairs(newMetadata) do
        if type(k) == "string" and utils.startsWith(k, "_") then
            newMetadata[k] = nil
        end
    end

    -- Sort dependencies by name
    newDependencies = table.sortby(newDependencies, function(dependency)
        return dependency.Name
    end)()

    local firstMetadata = newMetadata[1] or {}

    firstMetadata.Dependencies = newDependencies

    return newMetadata
end

local function updateMetadataFile(modName, metadata, newDependencies)
    local mountPoint = metadata._mountPoint
    local mountedFilename, filename = mods.findEverestYaml(mountPoint)

    if filename then
        local realFilename = utils.joinpath(love.filesystem.getRealDirectory(mountPoint), filename)
        local newMetadata = prepareMetadataForSaving(metadata, newDependencies)
        local success, reason = yaml.write(realFilename, newMetadata)

        return success
    end

    return false
end

local function updateSections(interactionData)
    -- "Move" sections from one category to the other
    -- Probably easier to delete and then generate a new one, potentially keeping expand status?

    -- TODO - Implement
end

local function getDependenciesList(modName)
    local currentModMetadata = mods.getModMetadataFromPath(modName)
    local firstMetadata = currentModMetadata and currentModMetadata[1] or {}
    local dependencies = firstMetadata.Dependencies or {}

    return dependencies, currentModMetadata
end

local function addDependencyCallback(modName, interactionData)
    return function()
        local dependencies, currentModMetadata = getDependenciesList(interactionData.modPath)
        local modInfo, modMetadata = mods.findLoadedMod(modName)
        local modVersion = modInfo and modInfo.Version

        table.insert(dependencies, {
            Name = modName,
            Version = modVersion
        })

        updateMetadataFile(modName, currentModMetadata, dependencies)
        updateSections(interactionData)
    end
end

local function removeDependencyCallback(modName, interactionData)
    return function()
        local dependencies, currentModMetadata = getDependenciesList(interactionData.modPath)

        for i = #dependencies, 1, -1 do
            local dependency = dependencies[i]

            if dependency.Name == modName then
                table.remove(dependencies, i)
            end
        end

        updateMetadataFile(modName, currentModMetadata, dependencies)
        updateSections(interactionData)
    end
end

local function generateCollapsableTree(data)
    local dataType = type(data)

    if dataType == "table" then
        local column = uiElements.column({})

        if #data == 0 then
            for text, subData in pairs(data) do
                local content = generateCollapsableTree(subData)

                if content then
                    local collapsable = collapsableWidget.getCollapsable(tostring(text), content)

                    column:addChild(collapsable)
                end
            end

        else
            for _, subData in ipairs(data) do
                column:addChild(uiElements.label(subData))
            end
        end

        return column

    elseif dataType == "string" then
        return uiElements.label(data)
    end
end

local function getModSection(modName, localizedModName, reasons, groupName, interactionData)
    local language = languageRegistry.getLanguage()
    local buttonAdds = groupName ~= "depended_on"
    local buttonLanguageKey = buttonAdds and "add_dependency" or "remove_dependency"
    local buttonText = tostring(language.ui.dependency_window[buttonLanguageKey])

    local buttonCallbackWrapper = buttonAdds and addDependencyCallback or removeDependencyCallback
    local buttonCallback = buttonCallbackWrapper(modName, interactionData)

    local modContent

    if reasons then
        modContent = generateCollapsableTree({[localizedModName] = reasons})

    else
        modContent = uiElements.label(localizedModName)
    end

    local actionButton = uiElements.button(buttonText, buttonCallback)
    local column = uiElements.column({
        modContent,
        actionButton
    })

    return column
end

local function calculateSecitonWidthHook(sections)
    return function(orig, self)
        local width = 0

        for _, section in ipairs(sections) do
            section:layoutLazy()

            width = math.max(width, section.width)
        end

        return width
    end
end

local function localizeModName(modName, language)
    local language = language or languageRegistry.getLanguage()
    local modNameLanguage = language.mods[modName].name

    if modNameLanguage._exists then
        return tostring(modNameLanguage)
    end

    return modName
end

local function getModSections(groupName, mods, addPadding, interactionData)
    local language = languageRegistry.getLanguage()
    local labelText = tostring(language.ui.dependency_window.group[groupName])

    local separator = uiElements.lineSeparator(labelText, 16, true)
    local column = uiElements.column({separator})

    if addPadding then
        separator:addBottomPadding()
    end

    local orderedSections = {}

    -- Sort by mod name
    for modName, reasons in pairs(mods) do
        local localizedModName = localizeModName(modName)
        local modSection = getModSection(modName, localizedModName, reasons, groupName, interactionData)

        if modSection then
            table.insert(orderedSections, {localizedModName, modSection})
        end
    end

    orderedSections = table.sortby(orderedSections, function(entry)
        return entry[1]
    end)()

    for _, entry in ipairs(orderedSections) do
        column:addChild(entry[2])
    end

    return column
end

function dependencyWindow.getWindowContent(modPath, side, interactionData)
    -- TODO - Hide current mod

    local currentModMetadata = mods.getModMetadataFromPath(modPath) or {}
    local dependedOnModNames = mods.getDependencyModNames(currentModMetadata)
    local availableModNames = mods.getAvailableModNames()
    local dependedOnModsLookup = table.flip(dependedOnModNames)

    local usedMods = dependencyFinder.analyzeSide(side)
    local missingMods = {}
    local dependedOnMods = {}
    local uncategorized = {}

    for modName, reasons in pairs(usedMods) do
        if not dependedOnModsLookup[modName] then
            missingMods[modName] = reasons

        else
            dependedOnMods[modName] = reasons
        end
    end

    for _, modName in ipairs(availableModNames) do
        if not missingMods[modName] and not dependedOnMods[modName] then
            uncategorized[modName] = false
        end
    end

    local hasMissingMods = utils.countKeys(missingMods) > 0
    local hasDependedOnMods = utils.countKeys(dependedOnMods) > 0
    local hasUncategorized = utils.countKeys(uncategorized) > 0

    local missingModsSection = getModSections("missing_mods", missingMods, false, interactionData)
    local dependedOnSection = getModSections("depended_on", dependedOnMods, hasMissingMods, interactionData)
    local uncategorizedSection = getModSections("available_mods", uncategorized, hasUncategorized, interactionData)

    -- TODO - Sections need to have the same width, otherwise the lineSeparator is cut off

    local column = uiElements.column({})
    local scrollableColumn = uiElements.scrollbox(column)

    if hasMissingMods then
        column:addChild(missingModsSection)
    end

    if hasDependedOnMods then
        column:addChild(dependedOnSection)
    end

    if hasUncategorized then
        column:addChild(uncategorizedSection)
    end

    scrollableColumn:hook({
        calcWidth = function(orig, element)
            return element.inner.width
        end,
    })
    scrollableColumn:with(uiUtils.fillHeight(true))

    return scrollableColumn
end

function dependencyWindow.editDependencies(filename, side)
    local modPath = mods.getFilenameModPath(filename)

    if not side or not modPath then
        return
    end

    local window
    local interactionData = {
        modPath = modPath,
        side = side,
    }

    local layout = dependencyWindow.getWindowContent(modPath, side, interactionData)

    local language = languageRegistry.getLanguage()
    local windowTitle = tostring(language.ui.dependency_window.window_title)

    local windowX = windowPreviousX
    local windowY = windowPreviousY

    -- Don't stack windows on top of each other
    if #activeWindows > 0 then
        windowX, windowY = 0, 0
    end

    window = uiElements.window(windowTitle, layout):with({
        x = windowX,
        y = windowY
    })

    interactionData.window = window

    table.insert(activeWindows, window)
    dependencyWindowGroup.parent:addChild(window)
    widgetUtils.addWindowCloseButton(window)
    window:with(widgetUtils.fillHeightIfNeeded())

    return window
end

-- Group to get access to the main group and sanely inject windows in it
function dependencyWindow.getWindow()
    dependencyEditor.dependencyWindow = dependencyWindow

    return dependencyWindowGroup
end

return dependencyWindow