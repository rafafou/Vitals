--!nonstrict
--[[
	==========================================================================
	  VITALS · MEMORY  (Memory Leak & Connection Tracker)  —  Plugin Roblox Studio
	==========================================================================
	Le fleau n2 de Roblox apres les exploiters : les connexions (:Connect) jamais
	deconnectees et les instances jamais detruites font gonfler la memoire
	jusqu'au crash. Roblox ne donne AUCUN moyen de voir quelle connexion fuit ni
	depuis quelle ligne.

	Ce plugin a deux moteurs :

	1) STATIQUE (onglet "Connexions") : scanne le code et repere les :Connect
	   au retour ignore cree dans un scope qui se repete (boucle, handler haute
	   frequence...), les Instance.new sans Destroy, l'absence de Maid/Trove.

	2) LIVE (onglet "Memoire") : pendant un playtest (F5), echantillonne la
	   memoire par categorie (Instances, Signals, LuaHeap...) et signale celles
	   qui ne font que monter — symptome classique d'une fuite.

	Installation : voir README_LeakTracker.md
	==========================================================================
]]

if not plugin then
	return
end

local Selection = game:GetService("Selection")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")

--==========================================================================
--  THEME
--==========================================================================

local themeProvider = settings().Studio.Theme
local function col(c, m)
	return themeProvider:GetColor(c, m)
end
local SGC = Enum.StudioStyleGuideColor

local SEVCOL = {
	High = Color3.fromRGB(255, 128, 0),
	Medium = Color3.fromRGB(240, 180, 0),
	Low = Color3.fromRGB(52, 120, 246),
	Info = Color3.fromRGB(130, 138, 145),
}
local SEVLABEL = { High = "ELEVE", Medium = "MOYEN", Low = "FAIBLE", Info = "INFO" }
local SEVRANK = { High = 4, Medium = 3, Low = 2, Info = 1 }

--==========================================================================
--  ANALYSE STATIQUE — utilitaires
--==========================================================================

local function sanitize(src)
	local out = {}
	local i, n = 1, #src
	local function peek(k) return string.sub(src, k, k) end
	while i <= n do
		local c = peek(i)
		if c == "\n" then
			out[#out + 1] = "\n"; i += 1
		elseif c == "-" and peek(i + 1) == "-" then
			local handled = false
			local j = i + 2
			if peek(j) == "[" then
				local k = j + 1
				local eqs = ""
				while peek(k) == "=" do eqs ..= "="; k += 1 end
				if peek(k) == "[" then
					local close = "]" .. eqs .. "]"
					local e = string.find(src, close, k + 1, true)
					local stop = e and (e + #close - 1) or n
					for p = i, stop do out[#out + 1] = (peek(p) == "\n") and "\n" or " " end
					i = stop + 1; handled = true
				end
			end
			if not handled then
				while i <= n and peek(i) ~= "\n" do out[#out + 1] = " "; i += 1 end
			end
		elseif c == '"' or c == "'" then
			local q = c
			out[#out + 1] = " "; i += 1
			while i <= n do
				local d = peek(i)
				if d == "\\" then
					out[#out + 1] = " "; out[#out + 1] = (peek(i + 1) == "\n") and "\n" or " "; i += 2
				elseif d == q then
					out[#out + 1] = " "; i += 1; break
				elseif d == "\n" then
					out[#out + 1] = "\n"; i += 1; break
				else
					out[#out + 1] = " "; i += 1
				end
			end
		elseif c == "[" then
			local k = i + 1
			local eqs = ""
			while peek(k) == "=" do eqs ..= "="; k += 1 end
			if peek(k) == "[" then
				local close = "]" .. eqs .. "]"
				local e = string.find(src, close, k + 1, true)
				local stop = e and (e + #close - 1) or n
				for p = i, stop do out[#out + 1] = (peek(p) == "\n") and "\n" or " " end
				i = stop + 1
			else
				out[#out + 1] = c; i += 1
			end
		else
			out[#out + 1] = c; i += 1
		end
	end
	return table.concat(out)
end

local function buildLineIndex(text)
	local starts = { 1 }
	local idx = string.find(text, "\n", 1, true)
	while idx do
		starts[#starts + 1] = idx + 1
		idx = string.find(text, "\n", idx + 1, true)
	end
	return starts
end

local function lineFromPos(starts, pos)
	local lo, hi = 1, #starts
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if starts[mid] <= pos then lo = mid else hi = mid - 1 end
	end
	return lo
end

local function lastSeg(path)
	return (string.match(path, "([%w_]+)%s*$")) or path
end

-- Signaux a haute frequence : un :Connect cree a l'interieur = fuite quasi sure.
local HIGH_FREQ = {
	Heartbeat = true, RenderStepped = true, Stepped = true, PreSimulation = true,
	PostSimulation = true, PreRender = true, Touched = true, TouchEnded = true,
	Changed = true, MouseMove = true, InputChanged = true, Activated = true,
}
local function freqOf(signalName)
	return HIGH_FREQ[signalName] and "high" or "low"
end

--==========================================================================
--  ANALYSE STATIQUE — contextes (boucles / handlers)
--==========================================================================

-- Construit la liste des blocs fermes {start, stop, kind, freq}.
-- kind : "handler" (fonction passee a :Connect), "loop", "fn", "if", "do".
local CTX_OPENERS = { ["function"] = true, ["if"] = true, ["for"] = true, ["while"] = true }

local function buildContexts(clean)
	-- Repere les positions de 'function' qui sont des handlers de :Connect.
	local handlerAt = {}
	do
		local pos = 1
		while true do
			local s, e, sig = string.find(clean, "([%w_%.]+):[Cc]onnect[%a]*%s*%(%s*function", pos)
			if not s then break end
			local fpos = string.find(clean, "function", s, true)
			if fpos then
				handlerAt[fpos] = freqOf(lastSeg(sig))
			end
			pos = e + 1
		end
	end

	local contexts = {}
	local stack = {}
	local pend = false
	local pos = 1
	while true do
		local s, e, w = string.find(clean, "([%a_][%w_]*)", pos)
		if not s then break end
		if w == "function" then
			if handlerAt[s] then
				table.insert(stack, { kind = "handler", freq = handlerAt[s], start = s })
			else
				table.insert(stack, { kind = "fn", start = s })
			end
		elseif w == "if" then
			table.insert(stack, { kind = "if", start = s })
		elseif w == "for" or w == "while" then
			table.insert(stack, { kind = "loop", freq = "high", start = s })
			pend = true
		elseif w == "do" then
			if pend then pend = false else table.insert(stack, { kind = "do", start = s }) end
		elseif w == "repeat" then
			table.insert(stack, { kind = "loop", freq = "high", start = s, rep = true })
		elseif w == "until" then
			for idx = #stack, 1, -1 do
				if stack[idx].rep then
					local c = table.remove(stack, idx)
					c.stop = e
					table.insert(contexts, c)
					break
				end
			end
		elseif w == "end" then
			local c = table.remove(stack)
			if c then
				c.stop = e
				table.insert(contexts, c)
			end
		end
		pos = e + 1
	end
	return contexts
end

-- Renvoie le contexte repetable (loop/handler) le plus interne contenant pos.
local function innermostRepeatable(contexts, pos)
	local best = nil
	for _, c in contexts do
		if (c.kind == "loop" or c.kind == "handler") and c.start < pos and pos < c.stop then
			if not best or c.start > best.start then
				best = c
			end
		end
	end
	return best
end

local MAID_TOKENS = { "[Mm]aid", "[Tt]rove", "[Jj]anitor", "GiveTask", "GivePromise", ":[Aa]dd%s*%(", ":[Gg]ive%s*%(" }
local function lineLooksManaged(lineText, prefixBeforeConnect)
	-- gere si le retour est capture (= avant le :Connect) ou ajoute a un Maid.
	if string.find(prefixBeforeConnect, "=") then
		return true
	end
	for _, t in MAID_TOKENS do
		if string.find(lineText, t) then
			return true
		end
	end
	return false
end

--==========================================================================
--  ANALYSE STATIQUE — collecte & passe
--==========================================================================

local SCAN_ROOT_NAMES = {
	"Workspace", "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService",
	"ServerStorage", "StarterGui", "StarterPack", "StarterPlayer", "Lighting", "SoundService",
}

local function getScanRoots()
	local roots = {}
	for _, name in SCAN_ROOT_NAMES do
		local ok, svc = pcall(function() return game:GetService(name) end)
		if ok and svc then table.insert(roots, svc) end
	end
	return roots
end

local function collectScripts()
	local scripts = {}
	for _, root in getScanRoots() do
		for _, inst in root:GetDescendants() do
			if inst:IsA("LuaSourceContainer") and inst ~= script then
				table.insert(scripts, inst)
			end
		end
	end
	return scripts
end

local function analyzeScript(scriptInst, findings)
	local okSrc, src = pcall(function() return scriptInst.Source end)
	if not okSrc or not src or src == "" then
		return okSrc
	end

	local clean = sanitize(src)
	local lineIndex = buildLineIndex(clean)
	local cleanLines = string.split(clean, "\n")
	local contexts = buildContexts(clean)
	local hasMaid = false
	for _, t in MAID_TOKENS do
		if string.find(clean, t) then hasMaid = true break end
	end

	local function add(severity, rule, line, title, detail, fix)
		table.insert(findings, {
			severity = severity, rule = rule, line = line, title = title,
			detail = detail, fix = fix, scriptInst = scriptInst,
		})
	end

	local discardedCount = 0

	-- Sites de creation de connexion
	local pos = 1
	while true do
		local s = string.find(clean, ":[Cc]onnect[%a]*%s*%(", pos)
		if not s then break end
		local line = lineFromPos(lineIndex, s)
		local lineText = cleanLines[line] or ""
		local lineStart = lineIndex[line] or 1
		local prefix = string.sub(clean, lineStart, s - 1)
		local managed = lineLooksManaged(lineText, prefix)

		if not managed then
			discardedCount += 1
			local anc = innermostRepeatable(contexts, s)
			if anc then
				local sev = (anc.freq == "high") and "High" or "Medium"
				local scope = (anc.kind == "loop") and "une boucle" or "un handler d'evenement"
				add(sev, "L1", line,
					string.format("Connexion non geree creee dans %s", scope),
					"Un :Connect dont le retour est ignore est cree a l'interieur d'un scope qui se "
						.. "repete. A chaque execution une nouvelle connexion s'empile et n'est jamais "
						.. "deconnectee : la memoire (Signals) grimpe sans jamais redescendre.",
					"Stocke la connexion (local conn = ...) et appelle conn:Disconnect() quand tu n'en "
						.. "as plus besoin, ou utilise un Maid/Trove/Janitor pour nettoyer automatiquement.")
			end
		end
		pos = s + 1
	end

	-- Instance.new dans un scope repetable sans Destroy proche
	pos = 1
	while true do
		local s = string.find(clean, "Instance%.new%s*%(", pos)
		if not s then break end
		local anc = innermostRepeatable(contexts, s)
		if anc then
			local body = string.sub(clean, anc.start, anc.stop)
			if not string.find(body, ":[Dd]estroy%s*%(") then
				local line = lineFromPos(lineIndex, s)
				add("Medium", "L4", line,
					"Instance.new dans un scope repetable sans Destroy",
					"Une instance est creee a chaque iteration/declenchement mais aucun :Destroy() "
						.. "n'apparait dans le meme bloc. Les instances s'accumulent (categorie Instances).",
					"Detruis l'instance quand elle n'est plus utile (:Destroy()), ou reutilise un pool "
						.. "d'objets au lieu d'en recreer.")
			end
		end
		pos = s + 1
	end

	-- L6 : beaucoup de connexions ignorees et aucun systeme de nettoyage
	if discardedCount >= 3 and not hasMaid then
		add("Info", "L6", 1,
			string.format("%d connexions au retour ignore, aucun Maid/Trove detecte", discardedCount),
			"Ce script cree plusieurs connexions sans garder de reference pour les nettoyer. "
				.. "Sans systeme de gestion, le risque de fuite augmente avec la taille du script.",
			"Adopte une librairie de nettoyage (Maid, Trove ou Janitor) pour deconnecter en un appel.")
	end

	return okSrc
end

local function runStaticAudit()
	local findings = {}
	local scripts = collectScripts()
	local readFailures = 0
	for _, s in scripts do
		local ok = analyzeScript(s, findings)
		if ok == false then readFailures += 1 end
	end
	table.sort(findings, function(a, b)
		local ra, rb = SEVRANK[a.severity], SEVRANK[b.severity]
		if ra ~= rb then return ra > rb end
		return (a.title or "") < (b.title or "")
	end)
	return { findings = findings, scriptCount = #scripts, readFailures = readFailures }
end

--==========================================================================
--  ANALYSE LIVE — suivi memoire
--==========================================================================

local MEM_METRICS = {
	{ key = "Total",     label = "Total",     color = Color3.fromRGB(124, 138, 255) },
	{ key = "Instances", label = "Instances", color = Color3.fromRGB(244, 114, 182) },
	{ key = "Signals",   label = "Signals",   color = Color3.fromRGB(52, 211, 153) },
	{ key = "LuaHeap",   label = "Lua Heap",  color = Color3.fromRGB(250, 204, 21) },
	{ key = "Script",    label = "Script",    color = Color3.fromRGB(248, 113, 113) },
}
local MAX_SAMPLES = 60
local memData = {}
for _, m in MEM_METRICS do memData[m.key] = {} end

local function sampleMemory()
	local function tagMb(tagName)
		local ok, v = pcall(function()
			return Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag[tagName])
		end)
		return ok and v or 0
	end
	local total = 0
	pcall(function() total = Stats:GetTotalMemoryUsageMb() end)
	local snap = {
		Total = total,
		Instances = tagMb("Instances"),
		Signals = tagMb("Signals"),
		LuaHeap = tagMb("LuaHeap"),
		Script = tagMb("Script"),
	}
	for _, m in MEM_METRICS do
		local arr = memData[m.key]
		table.insert(arr, snap[m.key])
		if #arr > MAX_SAMPLES then table.remove(arr, 1) end
	end
end

local function clearMemData()
	for _, m in MEM_METRICS do table.clear(memData[m.key]) end
end

-- Pente par moindres carres ; renvoie aussi le verdict.
local function trend(values)
	local n = #values
	if n < 6 then return 0, "—" end
	local sx, sy, sxx, sxy = 0, 0, 0, 0
	for i, y in values do
		sx += i; sy += y; sxx += i * i; sxy += i * y
	end
	local denom = (n * sxx - sx * sx)
	local slope = denom ~= 0 and (n * sxy - sx * sy) / denom or 0
	local first, last = values[1], values[n]
	local rising = slope > 0.03 and last > first + 0.5 and last > first * 1.05
	return slope, rising and "rising" or "stable"
end

--==========================================================================
--  UI
--==========================================================================

local toolbar = plugin:CreateToolbar("Vitals")
local button = toolbar:CreateButton(
	"Memory",
	"Vitals · Memory — detecte les fuites memoire et connexions",
	"rbxasset://textures/AnimationEditor/icon_unlocked.png"
)
button.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"MemoryLeakTracker",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 420, 580, 340, 400)
)
widget.Title = "Vitals · Memory"
widget.Name = "MemoryLeakTracker"

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

-- Barre d'onglets
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(1, 0, 0, 40)
tabBar.BackgroundColor3 = col(SGC.Titlebar)
tabBar.BorderSizePixel = 0
tabBar.Parent = root
padding(tabBar, 6)
local tabLayout = Instance.new("UIListLayout")
tabLayout.FillDirection = Enum.FillDirection.Horizontal
tabLayout.Padding = UDim.new(0, 6)
tabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
tabLayout.Parent = tabBar

local currentTab = "static"
local function makeTabButton(id, text, order)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0.5, -3, 1, 0)
	b.BackgroundColor3 = col(SGC.Button)
	b.TextColor3 = col(SGC.ButtonText)
	b.Text = text
	b.Font = Enum.Font.GothamBold
	b.TextSize = 12
	b.BorderSizePixel = 0
	b.LayoutOrder = order
	b.Parent = tabBar
	rounded(b, 6)
	return b
end
local tabStatic = makeTabButton("static", "🔌 Connexions", 1)
local tabLive = makeTabButton("live", "📈 Memoire (live)", 2)

-- Conteneur de pages
local pageHolder = Instance.new("Frame")
pageHolder.Size = UDim2.new(1, 0, 1, -40)
pageHolder.Position = UDim2.new(0, 0, 0, 40)
pageHolder.BackgroundTransparency = 1
pageHolder.Parent = root

----------------------------------------------------------------------------
-- PAGE STATIQUE
----------------------------------------------------------------------------
local staticPage = Instance.new("Frame")
staticPage.Size = UDim2.fromScale(1, 1)
staticPage.BackgroundTransparency = 1
staticPage.Parent = pageHolder

local sHeader = Instance.new("Frame")
sHeader.Size = UDim2.new(1, 0, 0, 70)
sHeader.BackgroundColor3 = col(SGC.Titlebar)
sHeader.BorderSizePixel = 0
sHeader.Parent = staticPage
padding(sHeader, 10)
local sHeadList = Instance.new("UIListLayout")
sHeadList.Padding = UDim.new(0, 6)
sHeadList.Parent = sHeader

local scanBtn = Instance.new("TextButton")
scanBtn.Size = UDim2.new(1, 0, 0, 32)
scanBtn.BackgroundColor3 = Color3.fromRGB(52, 120, 246)
scanBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
scanBtn.Text = "  ▶  Scanner l'hygiene des connexions"
scanBtn.Font = Enum.Font.GothamBold
scanBtn.TextSize = 14
scanBtn.BorderSizePixel = 0
scanBtn.LayoutOrder = 1
scanBtn.Parent = sHeader
rounded(scanBtn, 6)

local sSummary = Instance.new("TextLabel")
sSummary.Size = UDim2.new(1, 0, 0, 24)
sSummary.BackgroundTransparency = 1
sSummary.Text = "Repere les :Connect qui fuient (analyse statique)."
sSummary.TextColor3 = col(SGC.DimmedText)
sSummary.TextXAlignment = Enum.TextXAlignment.Left
sSummary.Font = Enum.Font.Gotham
sSummary.TextSize = 12
sSummary.TextWrapped = true
sSummary.LayoutOrder = 2
sSummary.Parent = sHeader

local sScroll = Instance.new("ScrollingFrame")
sScroll.Size = UDim2.new(1, 0, 1, -70)
sScroll.Position = UDim2.new(0, 0, 0, 70)
sScroll.BackgroundColor3 = col(SGC.MainBackground)
sScroll.BorderSizePixel = 0
sScroll.ScrollBarThickness = 8
sScroll.CanvasSize = UDim2.new()
sScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
sScroll.Parent = staticPage
padding(sScroll, 8)
local sScrollList = Instance.new("UIListLayout")
sScrollList.Padding = UDim.new(0, 8)
sScrollList.SortOrder = Enum.SortOrder.LayoutOrder
sScrollList.Parent = sScroll

local function clearChildren(p)
	for _, ch in p:GetChildren() do
		if ch:IsA("GuiObject") then ch:Destroy() end
	end
end

local function makeFindingCard(finding, order)
	local sevColor = SEVCOL[finding.severity]
	local card = Instance.new("TextButton")
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = col(SGC.Item)
	card.AutoButtonColor = false
	card.Text = ""
	card.BorderSizePixel = 0
	card.LayoutOrder = order
	card.Parent = sScroll
	rounded(card, 6)
	padding(card, 10)

	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(0, 4, 1, 0)
	bar.Position = UDim2.new(0, -10, 0, 0)
	bar.BackgroundColor3 = sevColor
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
		sevColor:ToHex(), SEVLABEL[finding.severity], finding.rule)
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
	fix.Text = '<b><font color="#5cb85c">Fix :</font></b> ' .. finding.fix
	fix.TextColor3 = col(SGC.DimmedText)
	fix.TextXAlignment = Enum.TextXAlignment.Left
	fix.TextWrapped = true
	fix.Font = Enum.Font.Gotham
	fix.TextSize = 12
	fix.LayoutOrder = 4
	fix.Parent = card

	local loc = Instance.new("TextLabel")
	loc.Size = UDim2.new(1, 0, 0, 15)
	loc.BackgroundTransparency = 1
	local locText = "—"
	if finding.scriptInst then
		locText = finding.scriptInst:GetFullName() .. ":" .. tostring(finding.line)
	end
	loc.Text = "📄 " .. locText .. "   (clic pour ouvrir)"
	loc.TextColor3 = Color3.fromRGB(120, 160, 235)
	loc.TextXAlignment = Enum.TextXAlignment.Left
	loc.TextTruncate = Enum.TextTruncate.AtEnd
	loc.Font = Enum.Font.RobotoMono
	loc.TextSize = 11
	loc.LayoutOrder = 5
	loc.Parent = card

	card.MouseButton1Click:Connect(function()
		local inst = finding.scriptInst
		if not inst then return end
		Selection:Set({ inst })
		if inst:IsA("LuaSourceContainer") then
			pcall(function() plugin:OpenScript(inst, finding.line or 1) end)
		end
	end)
	return card
end

local function doStaticScan()
	scanBtn.Text = "  ⏳  Analyse..."
	scanBtn.Active = false
	task.wait()
	local ok, result = pcall(runStaticAudit)
	scanBtn.Text = "  ▶  Relancer le scan"
	scanBtn.Active = true
	clearChildren(sScroll)
	if not ok then
		sSummary.Text = "Erreur : " .. tostring(result)
		sSummary.TextColor3 = SEVCOL.High
		return
	end
	local high = 0
	for _, f in result.findings do if f.severity == "High" then high += 1 end end
	sSummary.Text = string.format("%d scripts analyses • %d alertes (%d a haut risque)",
		result.scriptCount, #result.findings, high)
	sSummary.TextColor3 = (high > 0) and SEVCOL.High or col(SGC.DimmedText)
	if result.readFailures > 0 then
		sSummary.Text ..= string.format("  ⚠ %d script(s) illisibles (permission Injection de script).", result.readFailures)
	end
	if #result.findings == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, 0, 0, 40)
		empty.BackgroundTransparency = 1
		empty.Text = "✅ Aucune connexion suspecte trouvee."
		empty.TextColor3 = col(SGC.DimmedText)
		empty.TextWrapped = true
		empty.Font = Enum.Font.Gotham
		empty.TextSize = 13
		empty.Parent = sScroll
	else
		for i, f in result.findings do
			makeFindingCard(f, i)
		end
	end
end
scanBtn.MouseButton1Click:Connect(doStaticScan)

----------------------------------------------------------------------------
-- PAGE LIVE
----------------------------------------------------------------------------
local livePage = Instance.new("Frame")
livePage.Size = UDim2.fromScale(1, 1)
livePage.BackgroundTransparency = 1
livePage.Visible = false
livePage.Parent = pageHolder
padding(livePage, 10)

local liveStatus = Instance.new("TextLabel")
liveStatus.Size = UDim2.new(1, 0, 0, 40)
liveStatus.BackgroundTransparency = 1
liveStatus.Text = "▶ Lance un playtest (F5) pour demarrer le suivi memoire."
liveStatus.TextColor3 = col(SGC.DimmedText)
liveStatus.TextXAlignment = Enum.TextXAlignment.Left
liveStatus.TextWrapped = true
liveStatus.Font = Enum.Font.GothamMedium
liveStatus.TextSize = 13
liveStatus.Parent = livePage

local resetBtn = Instance.new("TextButton")
resetBtn.Size = UDim2.new(0, 130, 0, 24)
resetBtn.Position = UDim2.new(1, -130, 0, 8)
resetBtn.AnchorPoint = Vector2.new(0, 0)
resetBtn.BackgroundColor3 = col(SGC.Button)
resetBtn.TextColor3 = col(SGC.ButtonText)
resetBtn.Text = "🗑 Reset le graphe"
resetBtn.Font = Enum.Font.GothamMedium
resetBtn.TextSize = 11
resetBtn.BorderSizePixel = 0
resetBtn.Parent = livePage
rounded(resetBtn, 5)
resetBtn.MouseButton1Click:Connect(function() clearMemData() end)

local metricHolder = Instance.new("Frame")
metricHolder.Size = UDim2.new(1, 0, 1, -52)
metricHolder.Position = UDim2.new(0, 0, 0, 52)
metricHolder.BackgroundTransparency = 1
metricHolder.Parent = livePage
local metricList = Instance.new("UIListLayout")
metricList.Padding = UDim.new(0, 10)
metricList.Parent = metricHolder

-- Une carte par metrique (label, valeur, sparkline, verdict)
local metricCards = {}
for i, m in MEM_METRICS do
	local cardm = Instance.new("Frame")
	cardm.Size = UDim2.new(1, 0, 0, 78)
	cardm.BackgroundColor3 = col(SGC.Item)
	cardm.BorderSizePixel = 0
	cardm.LayoutOrder = i
	cardm.Parent = metricHolder
	rounded(cardm, 8)
	padding(cardm, 10)

	local topRow = Instance.new("Frame")
	topRow.Size = UDim2.new(1, 0, 0, 20)
	topRow.BackgroundTransparency = 1
	topRow.Parent = cardm

	local nameL = Instance.new("TextLabel")
	nameL.Size = UDim2.new(0.5, 0, 1, 0)
	nameL.BackgroundTransparency = 1
	nameL.Text = m.label
	nameL.TextColor3 = m.color
	nameL.TextXAlignment = Enum.TextXAlignment.Left
	nameL.Font = Enum.Font.GothamBold
	nameL.TextSize = 13
	nameL.Parent = topRow

	local valL = Instance.new("TextLabel")
	valL.Size = UDim2.new(0.5, 0, 1, 0)
	valL.Position = UDim2.new(0.5, 0, 0, 0)
	valL.BackgroundTransparency = 1
	valL.Text = "— MB"
	valL.TextColor3 = col(SGC.MainText)
	valL.TextXAlignment = Enum.TextXAlignment.Right
	valL.Font = Enum.Font.RobotoMono
	valL.TextSize = 13
	valL.Parent = topRow

	local spark = Instance.new("Frame")
	spark.Size = UDim2.new(1, 0, 0, 30)
	spark.Position = UDim2.new(0, 0, 0, 24)
	spark.BackgroundColor3 = col(SGC.ScrollBarBackground)
	spark.BorderSizePixel = 0
	spark.Parent = cardm
	rounded(spark, 4)
	local sparkList = Instance.new("UIListLayout")
	sparkList.FillDirection = Enum.FillDirection.Horizontal
	sparkList.HorizontalAlignment = Enum.HorizontalAlignment.Right
	sparkList.VerticalAlignment = Enum.VerticalAlignment.Bottom
	sparkList.Padding = UDim.new(0, 1)
	sparkList.Parent = spark

	local verdict = Instance.new("TextLabel")
	verdict.Size = UDim2.new(1, 0, 0, 14)
	verdict.Position = UDim2.new(0, 0, 0, 58)
	verdict.BackgroundTransparency = 1
	verdict.Text = ""
	verdict.TextColor3 = col(SGC.DimmedText)
	verdict.TextXAlignment = Enum.TextXAlignment.Left
	verdict.Font = Enum.Font.Gotham
	verdict.TextSize = 11
	verdict.Parent = cardm

	metricCards[m.key] = { value = valL, spark = spark, verdict = verdict, color = m.color }
end

local function drawSparkline(holder, values, color)
	clearChildren(holder)
	local maxV = 0.0001
	for _, v in values do if v > maxV then maxV = v end end
	for _, v in values do
		local b = Instance.new("Frame")
		b.Size = UDim2.new(0, 3, math.clamp(v / maxV, 0.02, 1), 0)
		b.BackgroundColor3 = color
		b.BorderSizePixel = 0
		b.Parent = holder
	end
end

local function refreshLiveUI()
	local running = RunService:IsRunning()
	if running then
		liveStatus.Text = "● Playtest en cours — suivi memoire actif."
		liveStatus.TextColor3 = Color3.fromRGB(52, 211, 153)
	else
		liveStatus.Text = "▶ Lance un playtest (F5) pour demarrer le suivi memoire."
		liveStatus.TextColor3 = col(SGC.DimmedText)
	end
	for _, m in MEM_METRICS do
		local arr = memData[m.key]
		local card = metricCards[m.key]
		local cur = arr[#arr]
		card.value.Text = cur and string.format("%.1f MB", cur) or "— MB"
		drawSparkline(card.spark, arr, card.color)
		local _, verdict = trend(arr)
		if verdict == "rising" then
			card.verdict.Text = "⚠ en hausse continue — fuite possible"
			card.verdict.TextColor3 = SEVCOL.High
		elseif verdict == "stable" then
			card.verdict.Text = "stable"
			card.verdict.TextColor3 = Color3.fromRGB(52, 211, 153)
		else
			card.verdict.Text = "en attente de donnees..."
			card.verdict.TextColor3 = col(SGC.DimmedText)
		end
	end
end

-- Boucle d'echantillonnage (1 Hz pendant le playtest)
task.spawn(function()
	while widget and widget.Parent do
		if RunService:IsRunning() then
			sampleMemory()
		end
		if widget.Enabled and currentTab == "live" then
			refreshLiveUI()
		end
		task.wait(1)
	end
end)

----------------------------------------------------------------------------
-- Onglets : bascule
----------------------------------------------------------------------------
local function selectTab(id)
	currentTab = id
	local activeCol = Color3.fromRGB(52, 120, 246)
	tabStatic.BackgroundColor3 = (id == "static") and activeCol or col(SGC.Button)
	tabStatic.TextColor3 = (id == "static") and Color3.fromRGB(255, 255, 255) or col(SGC.ButtonText)
	tabLive.BackgroundColor3 = (id == "live") and activeCol or col(SGC.Button)
	tabLive.TextColor3 = (id == "live") and Color3.fromRGB(255, 255, 255) or col(SGC.ButtonText)
	staticPage.Visible = (id == "static")
	livePage.Visible = (id == "live")
	if id == "live" then refreshLiveUI() end
end
tabStatic.MouseButton1Click:Connect(function() selectTab("static") end)
tabLive.MouseButton1Click:Connect(function() selectTab("live") end)
selectTab("static")

button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	button:SetActive(widget.Enabled)
end)
button:SetActive(widget.Enabled)
