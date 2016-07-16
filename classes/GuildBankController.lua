CBE_GuildBankController = ZO_Object:Subclass()

function CBE_GuildBankController:New(...)
    local controller = ZO_Object.New(self)
    controller:Initialize(...)
    return controller
end

function CBE_GuildBankController:Initialize()

    self.name = "CBE_GuildBankController"
    self.bankTransferQueue = CBE_TransferQueue:New(self.name.."Queue")
    self.withdrawalQueue = CBE_TransferQueue:New(self.name.."WithdrawalQueue")
    self.debug = false
    
    -- used by SwitchScene() below
    local guildBankFragments = {
        [SI_BANK_WITHDRAW] = { GUILD_BANK_FRAGMENT },
        [SI_BANK_DEPOSIT]  = { INVENTORY_FRAGMENT, BACKPACK_GUILD_BANK_LAYOUT_FRAGMENT },
        [SI_INVENTORY_MODE_CRAFT_BAG] = { CRAFT_BAG_FRAGMENT },
    }
    
    -- used by OnGuildBankSceneStateChange() below
    local anchors = { }
    
    --[[ Removes and adds the appropriate window fragments to display the given tabs. ]]
    local function SwitchScene(oldScene, newScene) 
    
        -- Remove the old tab's fragments
        local removeFragments = guildBankFragments[oldScene]
        for i,removeFragment in pairs(removeFragments) do
            SCENE_MANAGER:RemoveFragment(removeFragment)
        end
        
        -- Move the item count bar at the bottom to the correct window
        if newScene == SI_INVENTORY_MODE_CRAFT_BAG then
            ZO_PlayerInventoryInfoBar:SetParent(ZO_CraftBag)
        elseif oldScene == SI_INVENTORY_MODE_CRAFT_BAG then
            ZO_PlayerInventoryInfoBar:SetParent(ZO_PlayerInventory)
        end
        
        -- Add the new tab's fragments
        local addFragments = guildBankFragments[newScene]
        for i,addFragment in pairs(addFragments) do
            SCENE_MANAGER:AddFragment(addFragment)
        end
    end

    --[[ Handle button clicks for deposit, withdraw, and craft bag buttons. ]]
    local function OnGuildBankTabChanged(buttonData, playerDriven)

        -- If the scene is in the process of showing still, no switch is needed
        local guildBankSceneState = SCENE_MANAGER.scenes["guildBank"].state
        if guildBankSceneState == SCENE_SHOWING then 
            -- Remember the previous tab so we know which scene to hide when changing
            self.lastButtonDescriptor = buttonData.descriptor
            return 
        end
        
        -- Show or hide the craft bag window
        if buttonData.descriptor == SI_INVENTORY_MODE_CRAFT_BAG or self.lastButtonDescriptor == SI_INVENTORY_MODE_CRAFT_BAG then
            SwitchScene(self.lastButtonDescriptor, buttonData.descriptor)
        end
        
        -- Remember the previous tab so we know which scene to hide when changing
        self.lastButtonDescriptor = buttonData.descriptor
    end

    --[[ Handle guild bank screen open/close events ]]
    local function OnGuildBankSceneStateChange(oldState, newState)
        local anchorTemplate
        
        -- On enter, set craft bag window anchors to be the same as the guild 
        -- bank window's anchors
        if(newState == SCENE_SHOWING) then
            anchorTemplate = ZO_GuildBank:GetName()
            
        -- On exit, stop any outstanding transfers and restore craft bag window 
        -- anchors.
        elseif(newState == SCENE_HIDDEN) then
            CBE.Inventory.backpackTransferQueue:Clear()
            self.bankTransferQueue:Clear()
            anchorTemplate = ZO_CraftBag:GetName()
        else
            return
        end
        
        --[[ Hacky way to adjust the craft bag window position when guild bank 
             scene is opened/closed.
             Probably better to use backpack layout fragments in the future.
             See EsoUI/ingame/inventory/backpacklayouts.lua for examples. ]]
        ZO_CraftBag:ClearAnchors()
        for i=0,1 do
            local anchor = anchors[anchorTemplate][i]
            ZO_CraftBag:SetAnchor(anchor.point, anchor.relativeTo, anchor.relativePoint, anchor.offsetX, anchor.offsetY)
        end
    end
    
    --[[ Save anchor positions for the guild bank and craft bag windows for use
         on open/close events. ]]
    local windowAnchorsToSave = { ZO_GuildBank, ZO_CraftBag }
    for i,window in pairs(windowAnchorsToSave) do
        local windowAnchors = {}
        for j=0,1 do
            local isValidAnchor, point, relativeTo, relativePoint, offsetX, offsetY = window:GetAnchor(j)
            windowAnchors[j] = {
                point = point,
                relativeTo = relativeTo,
                relativePoint = relativePoint,
                offsetX = offsetX,
                offsetY = offsetY,    
            }
            anchors[window:GetName()] = windowAnchors
        end
    end
    SCENE_MANAGER.scenes["guildBank"]:RegisterCallback("StateChange",  OnGuildBankSceneStateChange)
    
    --[[ Wire up original guild bank buttons for tab changed event. ]]
    local buttons = ZO_GuildBankMenuBar.m_object.m_buttons
    for i, button in ipairs(buttons) do
        local buttonData = button[1].m_object.m_buttonData
        local callback = buttonData.callback
        buttonData.callback = function(...)
            OnGuildBankTabChanged(...)
            callback(...)
        end
    end
    
    --[[ Create craft bag button. ]]
    CBE:AddCraftBagButton(ZO_GuildBankMenuBar, 
        function (buttonData, playerDriven)
        
            -- Update the menu label to say "Craft Items"
            ZO_GuildBankMenuBarLabel:SetText(GetString(SI_INVENTORY_MODE_CRAFT_BAG))
            
            -- Tab changed callback
            OnGuildBankTabChanged(buttonData, playerDriven)
            
            -- Remove Deposit/withdraw keybind button when on craft bag tab
            local secondaryKeybindDescriptor = 
                KEYBIND_STRIP.keybinds["UI_SHORTCUT_SECONDARY"].keybindButtonDescriptor
            KEYBIND_STRIP:RemoveKeybindButton(secondaryKeybindDescriptor)
        end)
    
    
    --[[ When listening for a guild bank slot updated, handle any guild bank 
         transfer errors that get raised by stopping the transfer. ]]
    local function OnBankTransferFailed(eventCode, reason)
        if not self.bankTransferQueue:HasItems() then return end
        
        for i,transferItem in ipairs(self.bankTransferQueue.items) do
            
            local itemLink = GetItemLink(transferItem.bag, transferItem.slotIndex)
            CBE:Debug("Moving "..itemLink.." back to craft bag due to bank transfer error "..tostring(reason), self.debug)
            CBE.Inventory:TransferToCraftBag(transferItem.bag, transferItem.slotIndex)
        end
    end
    EVENT_MANAGER:RegisterForEvent(self.name, EVENT_GUILD_BANK_TRANSFER_ERROR, OnBankTransferFailed)
    
    
    
    --[[ FEATURE: DISABLE GUILD BANK AUTO-STASH TO CRAFT BAG ON WITHDRAWAL ]]--
    
    
    --[[ Listen for new guild bank craft material withdrawals and add them to 
         the pending withdrawal queue ]]
    local function OnGuildBankWithdrawal(slotId)
    
        local isVirtual = CanItemBeVirtual(BAG_GUILDBANK, slotId)
        CBE:Debug("Slot id "..tostring(slotId).." is virtual: "..tostring(isVirtual), self.debug)
        CBE:Debug("guildBankAutoStashOff: "..tostring(CBE.Settings.settings.guildBankAutoStashOff), self.debug)
        
        -- When auto-stash is off, watch for craft item withdrawals from the guild bank
        if not CBE.Settings.settings.guildBankAutoStashOff or not CanItemBeVirtual(BAG_GUILDBANK, slotId) then return end
        
        -- Save the withdrawal transferItem information to the queue
        self.withdrawalQueue:Enqueue(BAG_GUILDBANK, slotId, nil, BAG_VIRTUAL)
    end
    ZO_PreHook("TransferFromGuildBank", OnGuildBankWithdrawal)
    
    --[[ Process new craft bag slot updates that match stacks in the withdrawal
         queue by sending them back to the backpack. ]]
    local function OnInventorySlotUpdated(eventCode, bagId, slotId, isNewItem, itemSoundCategory, updateReason)
    
        if not CBE.Settings.settings.guildBankAutoStashOff then return end
        
        -- Make a craft bag item slot was just updated, and that we have guild
        -- bank crafting items in the guild bank withdrawal queue.
        if bagId ~= BAG_VIRTUAL or not self.withdrawalQueue:HasItems() then return end
        
        -- Try to find this specific craft bag item in the withdrawal queue
        local transferItem = self.withdrawalQueue:Dequeue(bagId, slotId)
        if not transferItem then return end
        
        -- Find the first free slot in the backpack
        local backpackSlotIndex = FindFirstEmptySlotInBag(BAG_BACKPACK)
        if not backpackSlotIndex then
            ZO_AlertEvent(EVENT_INVENTORY_IS_FULL, 1, 0)
            return
        end
        
        -- Refresh the tooltip counts once the stack makes it's way to the backpack
        CBE.Inventory:StartWaitingForTransfer(bagId, slotId, 
            function() CBE.Inventory:RefreshActiveTooltip() end, transferItem.quantity)
        
        -- Initiate the stack move to the backpack
        if IsProtectedFunction("RequestMoveItem") then
            CallSecureProtected("RequestMoveItem", bagId, slotId, BAG_BACKPACK, backpackSlotIndex, transferItem.quantity)
        else
            RequestMoveItem(bagId, slotId, BAG_BACKPACK, backpackSlotIndex, transferItem.quantity)
        end
        
        CBE:Debug("Transferring "..tostring(transferItem.quantity).." of "..transferItem.itemLink.." in craft bag slotId "..tostring(slotId).." back to backpack slot "..tostring(backpackSlotIndex)..", isNewItem: "..tostring(isNewItem)..", updateReason: "..updateReason, self.debug)
    end
    EVENT_MANAGER:RegisterForEvent(self.name, EVENT_INVENTORY_SINGLE_SLOT_UPDATE, OnInventorySlotUpdated)
    
    --[[ END FEATURE ]]--
    
    

    --[[ Handles bank item slot update events thrown from a "Deposit" action. ]]
    local function OnBankSlotUpdated(eventCode, slotId)

        CBE:Debug("bank transfer dequeue: "..tostring(eventCode)..", "..tostring(slotId), self.debug)
        local transferItem = self.bankTransferQueue:Dequeue(BAG_GUILDBANK, slotId)
        
        if not transferItem then 
            CBE:Debug("Not waiting for any bank transfers for guild bank slot "..tostring(slotId), self.debug)
            return 
        end
        
        -- Update the craft bag tooltip
        CBE.Inventory:RefreshActiveTooltip()
    end
    
    -- Listen for bank slot updates
    EVENT_MANAGER:RegisterForEvent(self.name, EVENT_GUILD_BANK_ITEM_ADDED, OnBankSlotUpdated)
end

--[[ Checks to ensure that there is a free inventory slot available in both the
     backpack and in the guild bank. If there is, returns true.  If not, an 
     alert is raised and returns false. ]]
local function ValidateFreeSlots(bag, slotIndex)
    if bag ~= BAG_VIRTUAL then return false end
    
    -- Don't transfer if you don't have enough free slots in the guild bank
    if GetNumBagFreeSlots(BAG_GUILDBANK) < 1 then
        ZO_AlertEvent(EVENT_GUILD_BANK_TRANSFER_ERROR, GUILD_BANK_NO_SPACE_LEFT)
        return false
    end
    
    -- Don't transfer if you don't have a free proxy slot in your backpack
    if GetNumBagFreeSlots(BAG_BACKPACK) < 1 then
        ZO_AlertEvent(EVENT_INVENTORY_IS_FULL, 1, 0)
        return false
    end
    
    return true
end

                

--[[ Adds guildbank-specific inventory slot crafting bag actions ]]
function CBE_GuildBankController:AddSlotActions(slotInfo)

    -- Only add these actions when the guild bank screen is open on the craft bag tab
    if GetInteractionType() ~= INTERACTION_GUILDBANK 
       or not GetSelectedGuildBankId() 
       or slotInfo.slotType ~= SLOT_TYPE_CRAFT_BAG_ITEM then 
        return 
    end
    local inventorySlot = slotInfo.inventorySlot
    local bag = slotInfo.bag
    local slotIndex = slotInfo.slotIndex
    
    --[[ Deposit ]]--
    slotInfo.slotActions:AddSlotAction(
        SI_BANK_DEPOSIT,  
        function() 
            if not ValidateFreeSlots(bag, slotIndex) then 
                CBE:Debug("free slot validation failed for bag "..tostring(bag).." index "..tostring(slotIndex), self.debug)
                return
            end
    
            local backpackSlotIndex = FindFirstEmptySlotInBag(BAG_BACKPACK)
            local stackSize, maxStackSize = GetSlotStackSize(bag, slotIndex)
            local quantity = math.min(stackSize, maxStackSize)
            
            -- Register the callback that will run after the stack makes its
            -- way to the backpack.
            if not CBE.Inventory:StartWaitingForTransfer(bag, slotIndex, 
                function(transferItem)
                                    
                    if not transferItem then
                        CBE:Debug(self.name..":OnBackpackTransferComplete did not receive its transferItem parameter", self.debug)
                    end

                    -- Listen for guild bank slot updates
                    CBE:Debug("bank transfer enqueue: "..tostring(transferItem.targetBag)..", "..tostring(transferItem.targetSlotIndex)..", "..tostring(transferItem.quantity)..", "..BAG_GUILDBANK, self.debug)
                    self.bankTransferQueue:Enqueue(transferItem.targetBag, transferItem.targetSlotIndex, transferItem.quantity, BAG_GUILDBANK)
                    
                    TransferToGuildBank(transferItem.targetBag, transferItem.targetSlotIndex)
                end, quantity) then 
                CBE:Debug("enqueue failed for bag "..tostring(bag).." index "..tostring(slotIndex), self.debug)
                return 
            end
            
            -- Initiate the stack move to the backpack
            if IsProtectedFunction("RequestMoveItem") then
                CallSecureProtected("RequestMoveItem", bag, slotIndex, BAG_BACKPACK, backpackSlotIndex, quantity)
            else
                RequestMoveItem(bag, slotIndex, BAG_BACKPACK, backpackSlotIndex, quantity)
            end
        end,
        "primary"
    )
    
    --[[ Retrieve and Deposit ]]--
    local actionName = SI_CBE_CRAFTBAG_BANK_DEPOSIT
    slotInfo.slotActions:AddSlotAction(
        actionName,  
        function()
            if not ValidateFreeSlots(bag, slotIndex) then return end
            
            CBE.Inventory:StartTransfer(inventorySlot, actionName, SI_ITEM_ACTION_BANK_DEPOSIT,
                function(transferItem)
                                    
                    if not transferItem then
                        CBE:Debug(self.name..":OnBackpackTransferComplete did not receive its transferItem parameter", self.debug)
                    end

                    -- Listen for guild bank slot updates
                    CBE:Debug("bank transfer enqueue: "..tostring(transferItem.targetBag)..", "..tostring(transferItem.targetSlotIndex)..", "..tostring(transferItem.quantity)..", "..BAG_GUILDBANK, self.debug)
                    self.bankTransferQueue:Enqueue(transferItem.targetBag, transferItem.targetSlotIndex, transferItem.quantity, BAG_GUILDBANK)
                    
                    TransferToGuildBank(transferItem.targetBag, transferItem.targetSlotIndex)
                end)
        end,
        "keybind1"
    )
end
