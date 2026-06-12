--!nonstrict
--[[
	==========================================================================
	  VITALS · PERFORMANCE  (Place Optimizer)  —  Plugin Roblox Studio
	==========================================================================
	Tout le monde veut un jeu qui charge vite et ne rame pas. Mais rien n'aide a
	trouver ce qui ALOURDIT un place : code mort, unions CSG, parts fantomes
	oubliees, milliers de parts sans streaming...

	Ce plugin scanne ton jeu, calcule un SCORE D'OPTIMISATION /100, et liste
	exactement quoi supprimer / corriger pour reduire le poids et accelerer le
	chargement. Clique une alerte pour selectionner les objets concernes dans
	l'Explorer.

	100% statique, ne modifie jamais ton jeu (il ne fait que selectionner).
	Installation : voir README_PlaceOptimizer.md
	==========================================================================
]]

if not plugin then
	return
end

local Selection = game:GetService("Selection")

--==========================================================================
--  THEME
--==========================================================================

local themeProvider = settings().Studio.Theme
local SGC = Enum.StudioStyleGuideColor
local function col(c, m) return themeProvider:GetColor(c, m) end

local SEV = {
	High   = { rank = 4, color = Color3.fromRGB(255, 128, 0),  label = "ELEVE",  penalty = 15 },
	Medium = { rank = 3, color = Color3.fromRGB(240, 180, 0),  label = "MOYEN",  penalty = 8 },
	Low    = { rank = 2, color = Color3.fromRGB(52, 120, 246), label = "FAIBLE", penalty = 3 },
	Info   = { rank = 1, color = Color3.fromRGB(130, 138, 145),label = "INFO",   penalty = 1 },
}

--==========================================================================
--  COLLECTE
--==========================================================================

local SCAN_ROOT_NAMES = {
	"Workspace", "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService",
	"ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "Lighting", "SoundService",
}

local MAX_PARTS_SCAN = 12000 -- garde-fou anti-freeze sur les tres gros jeux

local function getRoots()
	local roots = {}
	for _, name in SCAN_ROOT_NAMES do
		local ok, svc = pcall(function() return game:GetService(name) end)
		if ok and svc then table.insert(roots, svc) end
	end
	return roots
end

-- Echappe pour pattern Lua
local function esc(s)
	return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

-- Compte les occurrences d'un mot entier dans un texte.
local function countWord(text, word)
	local c = 0
	local pat = "%f[%w_]" .. esc(word) .. "%f[^%w_]"
	for _ in string.gmatch(text, pat) do c += 1 end
	return c
end

--==========================================================================
--  ANALYSE
--==========================================================================

local function runScan()
	local findings = {}
	local stats = { parts = 0, unions = 0, meshparts = 0, scripts = 0, modules = 0, decals = 0 }
	local readFailures = 0

	local allParts = {}        -- BaseParts (cap)
	local unions = {}
	local meshPrecise = {}
	local decals = {}
	local sourceContainers = {} -- {inst, src}
	local modules = {}          -- ModuleScripts
	local humanoidModels = {}   -- set des models de personnages

	-- Premier passage : Humanoids -> models de personnage a ignorer
	local wsOk, ws = pcall(function() return workspace end)
	if wsOk then
		for _, h in ws:GetDescendants() do
			if h:IsA("Humanoid") and h.Parent then
				humanoidModels[h.Parent] = true
			end
		end
	end
	local function inCharacter(inst)
		local m = inst:FindFirstAncestorOfClass("Model")
		while m do
			if humanoidModels[m] then return true end
			m = m:FindFirstAncestorOfClass("Model")
		end
		return false
	end

	-- Passage principal
	local partBudget = MAX_PARTS_SCAN
	for _, root in getRoots() do
		for _, inst in root:GetDescendants() do
			if inst:IsA("UnionOperation") then
				stats.unions += 1
				if #unions < 400 then table.insert(unions, inst) end
			elseif inst:IsA("MeshPart") then
				stats.meshparts += 1
				if inst.CollisionFidelity == Enum.CollisionFidelity.Precise and #meshPrecise < 400 then
					table.insert(meshPrecise, inst)
				end
			end

			if inst:IsA("BasePart") and partBudget > 0 then
				partBudget -= 1
				stats.parts += 1
				if #allParts < 6000 then table.insert(allParts, inst) end
			end

			if inst:IsA("Decal") or inst:IsA("Texture") or inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
				stats.decals += 1
				if #decals < 400 then table.insert(decals, inst) end
			end

			if inst:IsA("ModuleScript") then
				stats.modules += 1
				table.insert(modules, inst)
			end

			if inst:IsA("LuaSourceContainer") and inst ~= script then
				if inst:IsA("Script") or inst:IsA("LocalScript") then stats.scripts += 1 end
				local ok, src = pcall(function() return inst.Source end)
				if ok and src then
					table.insert(sourceContainers, { inst = inst, src = src })
				else
					readFailures += 1
				end
			end
		end
	end

	local function add(severity, rule, title, detail, fix, payload)
		local f = {
			severity = severity, rule = rule, title = title,
			detail = detail, fix = fix,
		}
		if payload then for k, v in payload do f[k] = v end end
		table.insert(findings, f)
	end

	-- Texte combine de toutes les sources (pour reperer le code mort)
	local combined = {}
	for _, sc in sourceContainers do combined[#combined + 1] = sc.src end
	local combinedText = table.concat(combined, "\n")

	-- O1 : ModuleScripts jamais references nulle part (code mort)
	do
		local unused = {}
		for _, mod in modules do
			-- occurrences du nom dans TOUT le code, moins celles dans son propre source
			local total = countWord(combinedText, mod.Name)
			local ownOk, ownSrc = pcall(function() return mod.Source end)
			local own = (ownOk and ownSrc) and countWord(ownSrc, mod.Name) or 0
			if (total - own) <= 0 then
				table.insert(unused, mod)
			end
		end
		if #unused > 0 then
			add("Medium", "O1",
				string.format("%d ModuleScript(s) jamais reference(s)", #unused),
				"Ces modules ne sont require()/cites nulle part dans le code. C'est probablement "
					.. "du code mort qui alourdit ton place et ralentit le chargement.",
				"Verifie puis supprime-les (ou archive-les hors du jeu). Conserve si tu les charges "
					.. "dynamiquement par nom.",
				{ instances = unused, count = #unused })
		end
	end

	-- O2 : scripts au code identique (copier-coller)
	do
		local bySource = {}
		for _, sc in sourceContainers do
			local key = sc.src:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
			if #key > 30 then -- ignore les scripts triviaux/vides
				bySource[key] = bySource[key] or {}
				table.insert(bySource[key], sc.inst)
			end
		end
		local dupGroups = 0
		local dupInstances = {}
		for _, group in bySource do
			if #group >= 2 then
				dupGroups += 1
				for _, g in group do table.insert(dupInstances, g) end
			end
		end
		if dupGroups > 0 then
			add("Low", "O2",
				string.format("%d groupe(s) de scripts identiques (%d copies)", dupGroups, #dupInstances),
				"Le meme code est copie-colle dans plusieurs scripts. Ca gonfle le place et rend la "
					.. "maintenance penible (corriger un bug = le corriger partout).",
				"Factorise le code commun dans un seul ModuleScript et require()-le.",
				{ instances = dupInstances, count = #dupInstances })
		end
	end

	-- O3 : scripts vides ou desactives (poids mort)
	do
		local dead = {}
		for _, sc in sourceContainers do
			local empty = string.match(sc.src, "^%s*$") ~= nil
			local disabled = false
			pcall(function()
				if (sc.inst:IsA("Script") or sc.inst:IsA("LocalScript")) and sc.inst.Disabled then
					disabled = true
				end
			end)
			if empty or disabled then
				table.insert(dead, sc.inst)
			end
		end
		if #dead > 0 then
			add("Low", "O3",
				string.format("%d script(s) vide(s) ou desactive(s)", #dead),
				"Des scripts vides ou desactives trainent dans le jeu : du poids mort sans aucune "
					.. "utilite.",
				"Supprime-les. Si un script est desactive temporairement, mets un commentaire pour t'en souvenir.",
				{ instances = dead, count = #dead })
		end
	end

	-- O4 : UnionOperations (CSG lourd / lent a charger)
	if stats.unions > 0 then
		local sev = (stats.unions >= 40) and "Medium" or "Low"
		add(sev, "O4",
			string.format("%d UnionOperation (CSG)", stats.unions),
			"Les unions CSG sont plus lourdes et plus lentes a charger que des MeshParts, et "
				.. "augmentent le temps de chargement initial du jeu.",
			"Convertis les grosses unions en MeshParts (clic droit > Export Selection, ou un outil "
				.. "de conversion). Garde les unions seulement quand c'est necessaire.",
			{ instances = unions, count = stats.unions })
	end

	-- O5 : parts fantomes (invisibles, sans collision, sans enfant)
	do
		local ghosts = {}
		for _, p in allParts do
			if p.Transparency >= 1 and not p.CanCollide and #p:GetChildren() == 0
				and not p:IsA("MeshPart") and not inCharacter(p) then
				table.insert(ghosts, p)
				if #ghosts >= 300 then break end
			end
		end
		if #ghosts > 0 then
			add("Info", "O5",
				string.format("%d part(s) fantome(s) probable(s)", #ghosts),
				"Ces parts sont totalement transparentes, sans collision et sans enfant : souvent des "
					.. "restes de prototypage oublies qui ne servent plus a rien.",
				"Verifie (certaines servent de reperes/hitbox invisibles) puis supprime celles qui sont "
					.. "vraiment inutiles.",
				{ instances = ghosts, count = #ghosts })
		end
	end

	-- O6 : parts non ancrees inutilement (cout physique)
	do
		local loose = {}
		for _, p in allParts do
			if not p.Anchored and p.CanCollide and not inCharacter(p)
				and not p:IsA("Seat") and not p:IsA("VehicleSeat") then
				if p:FindFirstChildWhichIsA("BodyMover") == nil then
					table.insert(loose, p)
					if #loose >= 400 then break end
				end
			end
		end
		if #loose >= 50 then
			add("Info", "O6",
				string.format("%d part(s) non ancree(s)", #loose),
				"Beaucoup de parts non ancrees : chacune est simulee par le moteur physique, ce qui "
					.. "coute du CPU serveur. La geometrie statique (decor) devrait etre ancree.",
				"Ancre (Anchored = true) tout ce qui ne doit pas bouger. Reserve la physique aux objets "
					.. "reellement dynamiques.",
				{ instances = loose, count = #loose })
		end
	end

	-- O7 : beaucoup de parts + StreamingEnabled desactive
	do
		local streaming = false
		pcall(function() streaming = workspace.StreamingEnabled end)
		if stats.parts >= 1000 and not streaming then
			add("Medium", "O7",
				string.format("%d parts dans le jeu, StreamingEnabled DESACTIVE", stats.parts),
				"Avec autant de parts et sans streaming, le client doit tout charger d'un coup : "
					.. "chargement lent et plus de memoire utilisee chez le joueur.",
				"Active workspace.StreamingEnabled : Roblox charge le monde par morceaux autour du "
					.. "joueur. C'est souvent le plus gros gain de temps de chargement.",
				{ instance = workspace })
		end
	end

	-- O8 : beaucoup de decals / textures (memoire graphique)
	if stats.decals >= 200 then
		add("Info", "O8",
			string.format("%d decals / textures / images", stats.decals),
			"Beaucoup d'assets image : chacun consomme de la memoire graphique et du temps de "
				.. "telechargement chez le joueur.",
			"Reutilise les memes textures, regroupe-les (atlas) et supprime les decals invisibles ou "
				.. "redondants.",
			{ instances = decals, count = stats.decals })
	end

	-- O9 : MeshParts en collision Precise (couteux)
	if #meshPrecise > 0 then
		add("Low", "O9",
			string.format("%d MeshPart en CollisionFidelity = Precise", #meshPrecise),
			"La collision 'Precise' sur un mesh est tres couteuse a calculer et a charger. Rarement "
				.. "necessaire pour du decor.",
			"Passe en CollisionFidelity = Box ou Hull quand la precision n'est pas indispensable.",
			{ instances = meshPrecise, count = #meshPrecise })
	end

	table.sort(findings, function(a, b)
		local ra, rb = SEV[a.severity].rank, SEV[b.severity].rank
		if ra ~= rb then return ra > rb end
		return (a.title or "") < (b.title or "")
	end)

	-- Score d'optimisation /100
	local penalty = 0
	for _, f in findings do penalty += SEV[f.severity].penalty end
	local score = math.clamp(100 - penalty, 0, 100)

	return { findings = findings, stats = stats, readFailures = readFailures, score = score }
end

--==========================================================================
--  UI
--==========================================================================

local toolbar = plugin:CreateToolbar("Vitals")
local button = toolbar:CreateButton(
	"Performance",
	"Vitals · Performance — reduis le poids et accelere le chargement",
	"rbxasset://textures/StudioToolbox/RecentlyUsed.png"
)
button.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"PlaceOptimizer",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 420, 600, 340, 420)
)
widget.Title = "Vitals · Performance"
widget.Name = "PlaceOptimizer"

local function rounded(inst, r)
	local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 6); c.Parent = inst
end
local function padding(inst, p)
	local u = Instance.new("UIPadding")
	u.PaddingLeft = UDim.new(0, p); u.PaddingRight = UDim.new(0, p)
	u.PaddingTop = UDim.new(0, p); u.PaddingBottom = UDim.new(0, p)
	u.Parent = inst
end

local root = Instance.new("Frame")
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = col(SGC.MainBackground)
root.BorderSizePixel = 0
root.Parent = widget
local rootList = Instance.new("UIListLayout")
rootList.SortOrder = Enum.SortOrder.LayoutOrder
rootList.Parent = root

-- Header
local HEADER_H = 150
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, HEADER_H)
header.BackgroundColor3 = col(SGC.Titlebar)
header.BorderSizePixel = 0
header.LayoutOrder = 1
header.Parent = root
padding(header, 10)
local headList = Instance.new("UIListLayout")
headList.Padding = UDim.new(0, 6)
headList.Parent = header

local scanBtn = Instance.new("TextButton")
scanBtn.Size = UDim2.new(1, 0, 0, 32)
scanBtn.BackgroundColor3 = Color3.fromRGB(52, 120, 246)
scanBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
scanBtn.Text = "  ▶  Analyser le poids du jeu"
scanBtn.Font = Enum.Font.GothamBold
scanBtn.TextSize = 14
scanBtn.BorderSizePixel = 0
scanBtn.LayoutOrder = 1
scanBtn.Parent = header
rounded(scanBtn, 6)

-- Carte score
local scoreCard = Instance.new("Frame")
scoreCard.Size = UDim2.new(1, 0, 0, 54)
scoreCard.BackgroundColor3 = col(SGC.Item)
scoreCard.BorderSizePixel = 0
scoreCard.LayoutOrder = 2
scoreCard.Parent = header
rounded(scoreCard, 6)
padding(scoreCard, 9)

local scoreNum = Instance.new("TextLabel")
scoreNum.Size = UDim2.new(0, 62, 1, 0)
scoreNum.BackgroundTransparency = 1
scoreNum.Text = "—"
scoreNum.Font = Enum.Font.GothamBold
scoreNum.TextSize = 30
scoreNum.TextXAlignment = Enum.TextXAlignment.Left
scoreNum.TextColor3 = col(SGC.DimmedText)
scoreNum.Parent = scoreCard

local scoreVerdict = Instance.new("TextLabel")
scoreVerdict.Position = UDim2.new(0, 68, 0, 0)
scoreVerdict.Size = UDim2.new(1, -68, 0, 18)
scoreVerdict.BackgroundTransparency = 1
scoreVerdict.Text = "Score d'optimisation — lance une analyse"
scoreVerdict.Font = Enum.Font.GothamMedium
scoreVerdict.TextSize = 13
scoreVerdict.TextXAlignment = Enum.TextXAlignment.Left
scoreVerdict.TextColor3 = col(SGC.MainText)
scoreVerdict.Parent = scoreCard

local gaugeBg = Instance.new("Frame")
gaugeBg.Position = UDim2.new(0, 68, 0, 24)
gaugeBg.Size = UDim2.new(1, -68, 0, 11)
gaugeBg.BackgroundColor3 = col(SGC.Border)
gaugeBg.BorderSizePixel = 0
gaugeBg.Parent = scoreCard
rounded(gaugeBg, 5)
local gaugeFill = Instance.new("Frame")
gaugeFill.Size = UDim2.new(0, 0, 1, 0)
gaugeFill.BackgroundColor3 = Color3.fromRGB(120, 130, 138)
gaugeFill.BorderSizePixel = 0
gaugeFill.Parent = gaugeBg
rounded(gaugeFill, 5)

local function setScore(score)
	if score == nil then
		scoreNum.Text = "—"
		scoreNum.TextColor3 = col(SGC.DimmedText)
		scoreVerdict.Text = "Score d'optimisation — lance une analyse"
		gaugeFill:TweenSize(UDim2.new(0, 0, 1, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.3, true)
		return
	end
	local color, verdict
	if score >= 85 then color, verdict = Color3.fromRGB(40, 180, 99), "Leger"
	elseif score >= 60 then color, verdict = Color3.fromRGB(240, 180, 0), "Correct"
	elseif score >= 35 then color, verdict = Color3.fromRGB(255, 128, 0), "Lourd"
	else color, verdict = Color3.fromRGB(220, 53, 69), "Tres lourd" end
	scoreNum.Text = tostring(score)
	scoreNum.TextColor3 = color
	scoreVerdict.Text = "Optimisation : " .. verdict
	gaugeFill.BackgroundColor3 = color
	gaugeFill:TweenSize(UDim2.new(score / 100, 0, 1, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.4, true)
end

local summary = Instance.new("TextLabel")
summary.Size = UDim2.new(1, 0, 0, 26)
summary.BackgroundTransparency = 1
summary.Text = "Analyse meshes, scripts, parts... et dit quoi alleger."
summary.TextColor3 = col(SGC.DimmedText)
summary.TextXAlignment = Enum.TextXAlignment.Left
summary.TextYAlignment = Enum.TextYAlignment.Top
summary.Font = Enum.Font.Gotham
summary.TextSize = 12
summary.TextWrapped = true
summary.LayoutOrder = 3
summary.Parent = header

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, 0, 1, -HEADER_H)
scroll.BackgroundColor3 = col(SGC.MainBackground)
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 8
scroll.CanvasSize = UDim2.new()
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.LayoutOrder = 2
scroll.Parent = root
padding(scroll, 8)
local scrollList = Instance.new("UIListLayout")
scrollList.Padding = UDim.new(0, 8)
scrollList.SortOrder = Enum.SortOrder.LayoutOrder
scrollList.Parent = scroll

local function clearChildren(p)
	for _, ch in p:GetChildren() do
		if ch:IsA("GuiObject") then ch:Destroy() end
	end
end

local function makeCard(finding, order)
	local sev = SEV[finding.severity]
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = col(SGC.Item)
	card.BorderSizePixel = 0
	card.LayoutOrder = order
	card.Parent = scroll
	rounded(card, 6)
	padding(card, 10)

	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(0, 4, 1, 0)
	bar.Position = UDim2.new(0, -10, 0, 0)
	bar.BackgroundColor3 = sev.color
	bar.BorderSizePixel = 0
	bar.Parent = card
	rounded(bar, 2)

	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 4)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = card

	local tag = Instance.new("TextLabel")
	tag.Size = UDim2.new(1, 0, 0, 15)
	tag.BackgroundTransparency = 1
	tag.RichText = true
	tag.Text = string.format('<font color="#%s"><b>● %s</b></font>  <font color="#888888">%s</font>',
		sev.color:ToHex(), sev.label, finding.rule)
	tag.TextXAlignment = Enum.TextXAlignment.Left
	tag.Font = Enum.Font.GothamBold
	tag.TextSize = 11
	tag.LayoutOrder = 1
	tag.Parent = card

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, 0, 0, 0)
	title.AutomaticSize = Enum.AutomaticSize.Y
	title.BackgroundTransparency = 1
	title.Text = finding.title
	title.TextColor3 = col(SGC.MainText)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.TextWrapped = true
	title.Font = Enum.Font.GothamMedium
	title.TextSize = 13
	title.LayoutOrder = 2
	title.Parent = card

	local detail = Instance.new("TextLabel")
	detail.Size = UDim2.new(1, 0, 0, 0)
	detail.AutomaticSize = Enum.AutomaticSize.Y
	detail.BackgroundTransparency = 1
	detail.Text = finding.detail
	detail.TextColor3 = col(SGC.DimmedText)
	detail.TextXAlignment = Enum.TextXAlignment.Left
	detail.TextWrapped = true
	detail.Font = Enum.Font.Gotham
	detail.TextSize = 12
	detail.LayoutOrder = 3
	detail.Parent = card

	local fix = Instance.new("TextLabel")
	fix.Size = UDim2.new(1, 0, 0, 0)
	fix.AutomaticSize = Enum.AutomaticSize.Y
	fix.BackgroundTransparency = 1
	fix.RichText = true
	fix.Text = '<b><font color="#5cb85c">Action :</font></b> ' .. finding.fix
	fix.TextColor3 = col(SGC.DimmedText)
	fix.TextXAlignment = Enum.TextXAlignment.Left
	fix.TextWrapped = true
	fix.Font = Enum.Font.Gotham
	fix.TextSize = 12
	fix.LayoutOrder = 4
	fix.Parent = card

	-- Bouton de selection
	local targets = finding.instances or (finding.instance and { finding.instance }) or {}
	if #targets > 0 then
		local selBtn = Instance.new("TextButton")
		selBtn.AutomaticSize = Enum.AutomaticSize.X
		selBtn.Size = UDim2.new(0, 0, 0, 24)
		selBtn.BackgroundColor3 = Color3.fromRGB(52, 120, 246)
		selBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		selBtn.Text = (#targets == 1) and "  🔎 Selectionner l'objet  "
			or string.format("  🔎 Selectionner les %d objets  ", #targets)
		selBtn.Font = Enum.Font.GothamBold
		selBtn.TextSize = 12
		selBtn.BorderSizePixel = 0
		selBtn.LayoutOrder = 5
		selBtn.Parent = card
		rounded(selBtn, 5)
		selBtn.MouseButton1Click:Connect(function()
			local valid = {}
			for _, t in targets do
				if t and t.Parent then table.insert(valid, t) end
				if #valid >= 200 then break end -- Selection capee pour rester fluide
			end
			pcall(function() Selection:Set(valid) end)
			if #valid == 1 and valid[1]:IsA("LuaSourceContainer") then
				pcall(function() plugin:OpenScript(valid[1]) end)
			end
		end)
	end

	return card
end

local function doScan()
	scanBtn.Text = "  ⏳  Analyse en cours..."
	scanBtn.Active = false
	task.wait()
	local ok, result = pcall(runScan)
	scanBtn.Text = "  ▶  Relancer l'analyse"
	scanBtn.Active = true
	clearChildren(scroll)

	if not ok then
		summary.Text = "Erreur : " .. tostring(result)
		summary.TextColor3 = SEV.High.color
		setScore(nil)
		return
	end

	setScore(result.score)
	local s = result.stats
	summary.Text = string.format("%d parts • %d unions • %d meshes • %d scripts • %d modules • %d images",
		s.parts, s.unions, s.meshparts, s.scripts, s.modules, s.decals)
	summary.TextColor3 = col(SGC.DimmedText)
	if result.readFailures > 0 then
		summary.Text ..= string.format("   ⚠ %d script(s) illisibles (permission Injection de script).", result.readFailures)
	end

	if #result.findings == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, 0, 0, 40)
		empty.BackgroundTransparency = 1
		empty.Text = "✅ Rien de notable a alleger. Beau jeu propre !"
		empty.TextColor3 = col(SGC.DimmedText)
		empty.TextWrapped = true
		empty.Font = Enum.Font.Gotham
		empty.TextSize = 13
		empty.Parent = scroll
	else
		for i, f in result.findings do
			makeCard(f, i)
		end
	end
end
scanBtn.MouseButton1Click:Connect(doScan)

button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	button:SetActive(widget.Enabled)
end)
button:SetActive(widget.Enabled)
