------------------------------------------------------------------------------
-- FILE:        Snow_Globe.lua
-- PURPOSE:     Ice Age-style map with snow-covered land and polar strategics.
------------------------------------------------------------------------------

include("MapGenerator");
include("FractalWorld");
include("FeatureGenerator");
include("TerrainGenerator");

local function GetPolarBandBounds()
	-- Use the same row count for both poles, never more than 20% of the height.
	local _, iH = Map.GetGridSize();
	local iBandRows = math.max(1, math.floor(iH * 0.20));
	return iBandRows, iH - iBandRows;
end

local function IsPolarPlot(plot, iSouthBoundary, iNorthBoundary)
	local iY = plot:GetY();
	return iY < iSouthBoundary or iY >= iNorthBoundary;
end

local function SetAllLandTerrain(terrainType)
	for _, plot in Plots() do
		if not plot:IsWater() then
			plot:SetTerrainType(terrainType, false, false);
		end
	end
end

local function RemoveInvalidSnowGlobeResources()
	local removed = 0;

	for _, plot in Plots() do
		if not plot:IsWater() then
			local resource = plot:GetResourceType();
			local usage = resource ~= -1 and Game.GetResourceUsageType(resource) or nil;
			if usage == ResourceUsageTypes.RESOURCEUSAGE_BONUS or
				usage == ResourceUsageTypes.RESOURCEUSAGE_LUXURY then
				local quantity = plot:GetNumResource();
				-- CanHaveResource rejects a plot that already contains a resource, so
				-- clear it briefly while checking the final Snow terrain.
				plot:SetResourceType(-1);
				if plot:CanHaveResource(resource, true, true) then
					plot:SetResourceType(resource, quantity);
				else
					removed = removed + 1;
				end
			end
		end
	end

	print("Snow Globe: removed", removed, "bonus/luxury resources invalid on Snow");
end

------------------------------------------------------------------------------
function GetMapScriptInfo()
	-- Temperature is omitted: every land tile becomes Snow regardless.
	local world_age, _, rainfall, sea_level, resources = GetCoreMapOptions();
	return {
		Name = "TXT_KEY_MAP_SNOW_GLOBE_VP",
		Description = "TXT_KEY_MAP_SNOW_GLOBE_HELP",
		IsAdvancedMap = false,
		IconIndex = 0,
		SortIndex = 1,
		CustomOptions = {world_age, rainfall, sea_level, resources},
	};
end
------------------------------------------------------------------------------

------------------------------------------------------------------------------
function GetMapInitData(worldSize)
	local worldsizes = {
		[GameInfo.Worlds.WORLDSIZE_DUEL.ID] = {32, 20},
		[GameInfo.Worlds.WORLDSIZE_TINY.ID] = {40, 24},
		[GameInfo.Worlds.WORLDSIZE_SMALL.ID] = {52, 32},
		[GameInfo.Worlds.WORLDSIZE_STANDARD.ID] = {64, 40},
		[GameInfo.Worlds.WORLDSIZE_LARGE.ID] = {84, 52},
		[GameInfo.Worlds.WORLDSIZE_HUGE.ID] = {104, 64},
	};
	local grid_size = worldsizes[worldSize];

	if grid_size then
		return {
			Width = grid_size[1],
			Height = grid_size[2],
			WrapX = true,
		};
	end
end
------------------------------------------------------------------------------

------------------------------------------------------------------------------
function GeneratePlotTypes()
	print("Generating Plot Types (Lua Snow Globe) ...");

	local sea_level = Map.GetCustomOption(3);
	if sea_level == 4 then
		sea_level = 1 + Map.Rand(3, "Random Sea Level - Snow Globe Lua");
	end

	local world_age = Map.GetCustomOption(1);
	if world_age == 4 then
		world_age = 1 + Map.Rand(3, "Random World Age - Snow Globe Lua");
	end

	local fractal_world = FractalWorld.Create();
	fractal_world:InitFractal{continent_grain = 2};
	local plotTypes = fractal_world:GeneratePlotTypes{
		sea_level = sea_level,
		world_age = world_age,
		sea_level_low = 65,
		sea_level_normal = 70,
		sea_level_high = 75,
		extra_mountains = 4,
		adjust_plates = 1.0,
		tectonic_islands = true,
	};

	SetPlotTypes(plotTypes);
	GenerateCoasts();
end
------------------------------------------------------------------------------

------------------------------------------------------------------------------
function GenerateTerrain()
	print("Generating Terrain (Lua Snow Globe) ...");

	-- Run the normal generator first so coast and ocean terrain are initialized,
	-- then replace every land terrain with snow.
	local terrain_generator = TerrainGenerator.Create();
	local terrainTypes = terrain_generator:GenerateTerrain();
	SetTerrainTypes(terrainTypes);

	SetAllLandTerrain(TerrainTypes.TERRAIN_SNOW);
end
------------------------------------------------------------------------------

------------------------------------------------------------------------------
function AddFeatures()
	print("Adding Features (Lua Snow Globe) ...");

	-- Snow Globe still needs the normal feature pass for polar ocean ice. The
	-- default FeatureGenerator guarantees ice on the first and last rows of a
	-- horizontally wrapping map and adds additional high-latitude ice.
	local rain = Map.GetCustomOption(2);
	if rain == 4 then
		rain = 1 + Map.Rand(3, "Random Rainfall - Snow Globe Lua");
	end

	local feature_generator = FeatureGenerator.Create{rainfall = rain};
	feature_generator:AddFeatures(false);
end
------------------------------------------------------------------------------

local function MoveStrategicResourcesToPoles(start_plot_database)
	local iSouthBoundary, iNorthBoundary = GetPolarBandBounds();
	local resources_to_move = {};
	-- Polar deposits by resource and land/water, used to absorb any deposit
	-- that cannot get a free polar tile of its own.
	local polar_deposits = {};

	local function AddPolarDeposit(plot, resource)
		local key = resource .. (plot:IsWater() and "w" or "l");
		polar_deposits[key] = polar_deposits[key] or {};
		table.insert(polar_deposits[key], plot);
	end

	-- Clear only non-polar strategic deposits. Deposits already in a polar band
	-- are left alone, avoiding unnecessary changes to the generated map.
	for _, plot in Plots() do
		local resource = plot:GetResourceType();
		if resource ~= -1 and
			Game.GetResourceUsageType(resource) == ResourceUsageTypes.RESOURCEUSAGE_STRATEGIC then
			if IsPolarPlot(plot, iSouthBoundary, iNorthBoundary) then
				AddPolarDeposit(plot, resource);
			else
				table.insert(resources_to_move, {
					plot = plot,
					resource = resource,
					quantity = plot:GetNumResource(),
					isWater = plot:IsWater(),
				});
				plot:SetResourceType(-1);
			end
		end
	end

	if table.maxn(resources_to_move) == 0 then
		return;
	end

	local land_candidates = {};
	local water_candidates = {};
	for _, plot in Plots() do
		local iPlotIndex = plot:GetIndex() + 1;
		local isReserved = start_plot_database and start_plot_database.playerCollisionData[iPlotIndex];
		if IsPolarPlot(plot, iSouthBoundary, iNorthBoundary) and
			plot:GetResourceType() == -1 and
			not plot:IsCity() and
			not plot:IsNaturalWonder(true) and
			not isReserved then
			if plot:IsWater() then
				-- Ice tiles cannot be worked, so a deposit under ice is useless.
				if plot:GetFeatureType() ~= FeatureTypes.FEATURE_ICE then
					table.insert(water_candidates, plot);
				end
			elseif not plot:IsMountain() then
				table.insert(land_candidates, plot);
			end
		end
	end

	-- Shuffle each candidate pool so resources are not concentrated at the
	-- first longitude scanned by Plots().
	local function Shuffle(list, label)
		for i = table.maxn(list), 2, -1 do
			local j = Map.Rand(i, label) + 1;
			list[i], list[j] = list[j], list[i];
		end
	end
	Shuffle(land_candidates, "Snow Globe polar land resource placement");
	Shuffle(water_candidates, "Snow Globe polar water resource placement");

	local moved, merged, stranded = 0, 0, 0;
	for _, entry in ipairs(resources_to_move) do
		local candidates = entry.isWater and water_candidates or land_candidates;
		local candidate = table.remove(candidates);
		if candidate then
			candidate:SetResourceType(entry.resource, entry.quantity);
			AddPolarDeposit(candidate, entry.resource);
			moved = moved + 1;
		else
			-- The polar rows have little free land (FractalWorld keeps the poles
			-- mostly water), so add the quantity to an existing polar deposit of
			-- the same resource instead of leaving it outside the bands.
			local deposits = polar_deposits[entry.resource .. (entry.isWater and "w" or "l")];
			if deposits then
				local target = deposits[Map.Rand(table.maxn(deposits), "Snow Globe polar resource merge") + 1];
				target:SetResourceType(entry.resource, target:GetNumResource() + entry.quantity);
				merged = merged + 1;
			else
				-- Never delete a resource. This only happens when the bands have
				-- no free tile and no deposit of this resource at all.
				entry.plot:SetResourceType(entry.resource, entry.quantity);
				stranded = stranded + 1;
				print("Snow Globe: no polar tile for strategic resource", entry.resource, "at", entry.plot:GetX(), entry.plot:GetY());
			end
		end
	end

	print("Snow Globe: polar rows", iSouthBoundary, "and", iNorthBoundary, "; strategic deposits moved", moved, "merged", merged, "left outside", stranded);
end
------------------------------------------------------------------------------

------------------------------------------------------------------------------
function StartPlotSystem()
	local res = Map.GetCustomOption(4);
	if res == 6 then
		res = 1 + Map.Rand(3, "Random Resources Option - Snow Globe Lua");
	end

	print("Creating start plot database (MapGenerator.Lua)");
	local start_plot_database = AssignStartingPlots.Create();

	-- AssignStartingPlots cannot run on Snow: Snow scores -1 fertility (breaking
	-- region division), city states reject every Snow tile, and most resource
	-- plot lists skip Snow. Every land tile is the same terrain either way, so
	-- start ranking still depends only on rivers, coast and hills. Use plains
	-- while it runs, then restore the map's intended snow terrain.
	SetAllLandTerrain(TerrainTypes.TERRAIN_PLAINS);

	print("Dividing the map into regions (Lua Snow Globe)");
	start_plot_database:GenerateRegions{method = 1, resources = res};

	print("Choosing start locations for civilizations (MapGenerator.Lua)");
	start_plot_database:ChooseLocations();

	print("Normalizing start locations and assigning them to players (MapGenerator.Lua)");
	start_plot_database:BalanceAndAssign();

	print("Placing Natural Wonders (MapGenerator.Lua)");
	start_plot_database:PlaceNaturalWonders();

	print("Placing Resources and City States (MapGenerator.Lua)");
	start_plot_database:PlaceResourcesAndCityStates();

	SetAllLandTerrain(TerrainTypes.TERRAIN_SNOW);
	RemoveInvalidSnowGlobeResources();

	-- Move strategics last: the bonus resources removed above free polar tiles.
	MoveStrategicResourcesToPoles(start_plot_database);
end
------------------------------------------------------------------------------
