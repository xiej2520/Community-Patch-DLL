-- Released under GPL v3
--------------------------------------------------------------
include("IGE_API_All");
print("IGE_WorldCongressPanel");

IGE = nil;
local isVisible = false;
local memberManager = CreateInstanceManager("CongressMemberInstance", "Root", Controls.MembersStack);
local inactiveManager = CreateInstanceManager("CongressResolutionInstance", "Root", Controls.InactiveStack);
local activeManager = CreateInstanceManager("CongressActiveResolutionInstance", "Root", Controls.ActiveStack);

local function GetLeague()
	return Game.GetActiveLeague();
end

local function HasEditorBindings(league)
	return league
		and league.GetExtraVotesForMember
		and league.SetExtraVotesForMember
		and league.SetHostMember
		and league.SetTurnsUntilSession ~= nil;
end

local function GetEditorPlayer(league)
	if league and league:IsMember(IGE.currentPlayerID) then
		return IGE.currentPlayerID;
	end
	return league and league:GetHostMember() or -1;
end

local function Refresh()
	LuaEvents.IGE_Update();
	Events.SerialEventGameDataDirty();
end

local function ConfirmChange(text, callback)
	LuaEvents.IGE_ConfirmPopup(text, function()
		callback();
		Refresh();
	end);
end

local function SetExtraDelegates(league, playerID, value)
	league:SetExtraVotesForMember(playerID, math.max(0, math.floor((tonumber(value) or 0) + 0.5)));
	Refresh();
end

local function SetResolutionTooltip(control, name, help)
	local item = { name = name, help = help or "" };
	control:SetToolTipCallback(function() ToolTipHandler(item) end);
	control:SetToolTipType("IGE_ToolTip");
end

local function AddMemberRow(league, playerID, inSession)
	local instance = memberManager:GetInstance();
	local player = Players[playerID];
	local isHost = league:IsHostMember(playerID);
	local total = league:CalculateStartingVotesForMember(playerID);
	local extra = league:GetExtraVotesForMember(playerID);

	instance.Name:SetText((isHost and "[ICON_CAPITAL] " or "") .. player:GetCivilizationShortDescription());
	instance.Total:SetText(tostring(total));
	instance.Total:SetToolTipString(inSession
		and L("TXT_KEY_IGE_CONGRESS_CURRENT_VOTES", league:GetRemainingVotesForMember(playerID), league:GetSpentVotesForMember(playerID))
		or L("TXT_KEY_IGE_CONGRESS_TOTAL_DELEGATES_HELP"));
	instance.ExtraEditBox:SetText(tostring(extra));
	instance.ExtraDown:SetDisabled(extra <= 0);
	instance.ExtraDown:RegisterCallback(Mouse.eLClick, function() SetExtraDelegates(league, playerID, extra - 1) end);
	instance.ExtraUp:RegisterCallback(Mouse.eLClick, function() SetExtraDelegates(league, playerID, extra + 1) end);
	instance.ExtraEditBox:RegisterCallback(function(value) SetExtraDelegates(league, playerID, value) end);
	instance.HostButton:SetText(isHost and L("TXT_KEY_IGE_CONGRESS_HOST") or L("TXT_KEY_IGE_CONGRESS_MAKE_HOST"));
	instance.HostButton:SetDisabled(isHost or inSession);
	instance.HostButton:RegisterCallback(Mouse.eLClick, function()
		ConfirmChange(L("TXT_KEY_IGE_CONGRESS_CONFIRM_HOST", player:GetCivilizationShortDescription()), function()
			league:SetHostMember(playerID);
		end);
	end);
end

local function IsExactResolutionActive(league, resolutionType, choice)
	for _, resolution in ipairs(league:GetActiveResolutions()) do
		if resolution.Type == resolutionType and resolution.ProposerDecision == choice then
			return true;
		end
	end
	return false;
end

local function AddInactiveResolutionRow(league, resolutionType, inSession)
	local info = GameInfo.Resolutions[resolutionType];
	if not info then return end
	local instance = inactiveManager:GetInstance();
	local actor = GetEditorPlayer(league);
	local decision = GameInfo.ResolutionDecisions[info.ProposerDecision];
	local decisionID = decision and decision.ID or -1;
	local choices = decision and league:GetChoicesForDecision(decisionID, actor) or {};
	local choice = (#choices > 0) and choices[1] or -1;
	local name = L(info.Description);
	local help = info.Help and L(info.Help) or "";

	instance.Name:SetText(name);
	SetResolutionTooltip(instance.Name, name, help);
	instance.Choice:ClearEntries();
	instance.Choice:SetHide(#choices == 0);
	if #choices > 0 then
		for _, value in ipairs(choices) do
			local entry = {};
			instance.Choice:BuildEntry("InstanceOne", entry);
			entry.Button:SetText(league:GetTextForChoice(decisionID, value));
			entry.Button:SetVoid1(value);
		end
		instance.Choice:CalculateInternals();
		instance.Choice:GetButton():SetText(league:GetTextForChoice(decisionID, choice));
		instance.Choice:RegisterSelectionCallback(function(value)
			choice = value;
			instance.Choice:GetButton():SetText(league:GetTextForChoice(decisionID, choice));
			instance.Action:SetDisabled(inSession or IsExactResolutionActive(league, resolutionType, choice));
		end);
	end

	instance.Action:SetText(L("TXT_KEY_IGE_CONGRESS_ENACT"));
	SetResolutionTooltip(instance.Action, name, help);
	instance.Action:SetDisabled(inSession or IsExactResolutionActive(league, resolutionType, choice));
	instance.Action:RegisterCallback(Mouse.eLClick, function()
		local name = league:GetResolutionName(resolutionType, -1, choice, false);
		ConfirmChange(L("TXT_KEY_IGE_CONGRESS_CONFIRM_ENACT", name), function()
			Game.DoEnactResolution(resolutionType, choice, actor);
		end);
	end);
end

local function AddActiveResolutionRow(league, resolution, inSession)
	local instance = activeManager:GetInstance();
	local actor = GetEditorPlayer(league);
	local name = league:GetResolutionName(resolution.Type, resolution.ID, resolution.ProposerDecision, false);
	local help = league:GetResolutionDetails(resolution.Type, actor, resolution.ID, resolution.ProposerDecision) or "";
	instance.Name:SetText(name);
	SetResolutionTooltip(instance.Name, name, help);
	instance.Action:SetText(L("TXT_KEY_IGE_CONGRESS_REPEAL"));
	SetResolutionTooltip(instance.Action, name, help);
	instance.Action:SetDisabled(inSession);
	instance.Action:RegisterCallback(Mouse.eLClick, function()
		ConfirmChange(L("TXT_KEY_IGE_CONGRESS_CONFIRM_REPEAL", name), function()
			Game.DoRepealResolution(resolution.Type, actor, resolution.ProposerDecision);
		end);
	end);
end

local function OnSharingGlobalAndOptions(_IGE)
	IGE = _IGE;
end
LuaEvents.IGE_SharingGlobalAndOptions.Add(OnSharingGlobalAndOptions);

function OnInitialize()
	Resize(Controls.Container);
	LuaEvents.IGE_RegisterTab("WORLD_CONGRESS", L("TXT_KEY_IGE_CONGRESS_PANEL"), 3, "change", L("TXT_KEY_IGE_CONGRESS_PANEL_HELP"));
end
LuaEvents.IGE_Initialize.Add(OnInitialize);

function OnSelectedPanel(ID)
	isVisible = (ID == "WORLD_CONGRESS");
end
LuaEvents.IGE_SelectedPanel.Add(OnSelectedPanel);

function OnUpdate()
	Controls.Container:SetHide(not isVisible);
	if not isVisible then return end
	LuaEvents.IGE_SetMouseMode(IGE_MODE_NONE);

	memberManager:ResetInstances();
	inactiveManager:ResetInstances();
	activeManager:ResetInstances();
	local league = GetLeague();
	Controls.NoLeague:SetHide(league ~= nil);
	local hasBindings = HasEditorBindings(league);
	Controls.MissingDLL:SetHide(league == nil or hasBindings);
	Controls.Content:SetHide(league == nil or not hasBindings);
	if not league then return end
	if not hasBindings then return end

	local inSession = league:IsInSession();
	Controls.Title:SetText(league:GetName());
	Controls.Status:SetText(inSession and L("TXT_KEY_IGE_CONGRESS_IN_SESSION") or L("TXT_KEY_IGE_CONGRESS_NEXT_SESSION", league:GetTurnsUntilSession()));
	Controls.TurnsEditBox:SetText(tostring(league:GetTurnsUntilSession()));
	Controls.TurnsDown:SetDisabled(inSession or league:GetTurnsUntilSession() <= 0);
	Controls.TurnsUp:SetDisabled(inSession);
	Controls.TurnsEditBox:SetDisabled(inSession);

	for playerID = 0, GameDefines.MAX_MAJOR_CIVS - 1 do
		if league:IsMember(playerID) and Players[playerID]:IsAlive() then
			AddMemberRow(league, playerID, inSession);
		end
	end
	for _, resolution in ipairs(league:GetInactiveResolutions()) do
		AddInactiveResolutionRow(league, resolution.Type, inSession);
	end
	for _, resolution in ipairs(league:GetActiveResolutions()) do
		AddActiveResolutionRow(league, resolution, inSession);
	end

	Controls.MembersStack:CalculateSize();
	Controls.InactiveStack:CalculateSize();
	Controls.ActiveStack:CalculateSize();
	Controls.MembersScroll:CalculateInternalSize();
	Controls.InactiveScroll:CalculateInternalSize();
	Controls.ActiveScroll:CalculateInternalSize();
end
LuaEvents.IGE_Update.Add(OnUpdate);

Controls.TurnsDown:RegisterCallback(Mouse.eLClick, function()
	local league = GetLeague();
	if league then league:SetTurnsUntilSession(math.max(0, league:GetTurnsUntilSession() - 1)); Refresh(); end
end);
Controls.TurnsUp:RegisterCallback(Mouse.eLClick, function()
	local league = GetLeague();
	if league then league:SetTurnsUntilSession(league:GetTurnsUntilSession() + 1); Refresh(); end
end);
Controls.TurnsEditBox:RegisterCallback(function(value)
	local league = GetLeague();
	value = math.max(0, math.floor((tonumber(value) or 0) + 0.5));
	if league then league:SetTurnsUntilSession(value); Refresh(); end
end);
