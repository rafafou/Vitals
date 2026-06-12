--!nonstrict
--[[
	==========================================================================
	  VITALS · SECURITY  (Remote Security Auditor)  —  Plugin Roblox Studio
	==========================================================================
	Audite la securite de tes RemoteEvent / RemoteFunction / UnreliableRemoteEvent.

	Le probleme : les exploiters detruisent les jeux en firant des remotes avec
	des arguments arbitraires (monnaie, degats, inventaire, teleportation...).
	La regle d'or "ne jamais faire confiance au client" est connue, mais AUCUN
	outil n'audite automatiquement TON jeu pour te dire OU tu es vulnerable.

	Ce plugin scanne le Source de tous tes scripts, retrouve chaque handler
	serveur (OnServerEvent / OnServerInvoke), et applique un moteur de regles
	pour reperer les patterns dangereux. Sortie = rapport clique-pour-ouvrir,
	avec script + ligne + fix suggere.

	Analyse 100% statique (ne lance pas le jeu). Heuristique : a utiliser comme
	une checklist de revue, pas comme une preuve formelle de securite.

	Installation : voir README.md
	==========================================================================
]]

if not plugin then
	return
end

--==========================================================================
--  SERVICES & ROOTS
--==========================================================================

local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")

local function safeService(name)
	local ok, svc = pcall(function()
		return game:GetService(name)
	end)
	return ok and svc or nil
end

-- Conteneurs scannes (on evite CoreGui et les GUIs de plugins)
local SCAN_ROOT_NAMES = {
	"Workspace", "ReplicatedStorage", "ReplicatedFirst",
	"ServerScriptService", "ServerStorage",
	"StarterGui", "StarterPack", "StarterPlayer",
	"Lighting", "SoundService", "Players", "Teams",
}

local function getScanRoots()
	local roots = {}
	for _, name in SCAN_ROOT_NAMES do
		local svc = safeService(name)
		if svc then
			table.insert(roots, svc)
		end
	end
	return roots
end

--==========================================================================
--  THEME (couleurs Studio claires/sombres)
--==========================================================================

local theme = settings().Studio.Theme

local function col(styleGuideColor, modifier)
	return theme:GetColor(styleGuideColor, modifier)
end

local SEVERITY = {
	Critical = { rank = 5, color = Color3.fromRGB(220, 53, 69),  label = "CRITIQUE" },
	High     = { rank = 4, color = Color3.fromRGB(255, 128, 0),  label = "ELEVE" },
	Medium   = { rank = 3, color = Color3.fromRGB(240, 180, 0),  label = "MOYEN" },
	Low      = { rank = 2, color = Color3.fromRGB(52, 120, 246), label = "FAIBLE" },
	Info     = { rank = 1, color = Color3.fromRGB(130, 138, 145),label = "INFO" },
}

--==========================================================================
--  ANALYSEUR — utilitaires
--==========================================================================

-- Echappe une string pour usage dans un pattern Lua.
local function escapePattern(s)
	return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

-- "Sanitize" : remplace le contenu des commentaires et des strings par des
-- espaces, en conservant EXACTEMENT la longueur (donc les numeros de ligne et
-- les positions restent valides). Evite que des mots-cles dans des strings ou
-- des commentaires faussent l'analyse.
local function sanitize(src)
	local out = {}
	local i = 1
	local n = #src
	local function peek(k)
		return string.sub(src, k, k)
	end

	while i <= n do
		local c = peek(i)

		if c == "\n" then
			out[#out + 1] = "\n"
			i += 1

		elseif c == "-" and peek(i + 1) == "-" then
			-- Commentaire (court ou long)
			local handled = false
			local j = i + 2
			if peek(j) == "[" then
				local k = j + 1
				local eqs = ""
				while peek(k) == "=" do
					eqs ..= "="
					k += 1
				end
				if peek(k) == "[" then
					local close = "]" .. eqs .. "]"
					local endIdx = string.find(src, close, k + 1, true)
					local stop = endIdx and (endIdx + #close - 1) or n
					for p = i, stop do
						out[#out + 1] = (peek(p) == "\n") and "\n" or " "
					end
					i = stop + 1
					handled = true
				end
			end
			if not handled then
				while i <= n and peek(i) ~= "\n" do
					out[#out + 1] = " "
					i += 1
				end
			end

		elseif c == '"' or c == "'" then
			-- String courte
			local quote = c
			out[#out + 1] = " "
			i += 1
			while i <= n do
				local d = peek(i)
				if d == "\\" then
					out[#out + 1] = " "
					out[#out + 1] = (peek(i + 1) == "\n") and "\n" or " "
					i += 2
				elseif d == quote then
					out[#out + 1] = " "
					i += 1
					break
				elseif d == "\n" then
					out[#out + 1] = "\n"
					i += 1
					break
				else
					out[#out + 1] = " "
					i += 1
				end
			end

		elseif c == "[" then
			-- String longue [[ ]] ou [=[ ]=]
			local k = i + 1
			local eqs = ""
			while peek(k) == "=" do
				eqs ..= "="
				k += 1
			end
			if peek(k) == "[" then
				local close = "]" .. eqs .. "]"
				local endIdx = string.find(src, close, k + 1, true)
				local stop = endIdx and (endIdx + #close - 1) or n
				for p = i, stop do
					out[#out + 1] = (peek(p) == "\n") and "\n" or " "
				end
				i = stop + 1
			else
				out[#out + 1] = c
				i += 1
			end

		else
			out[#out + 1] = c
			i += 1
		end
	end

	return table.concat(out)
end

-- Index des debuts de ligne pour convertir position -> numero de ligne.
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
		if starts[mid] <= pos then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return lo
end

-- Cherche la fin d'un corps de fonction par comptage de profondeur.
-- Demarre sur le mot-cle `function` du handler (depth passe a 1), s'arrete
-- quand le `end` correspondant ramene depth a 0. Renvoie la position de fin.
local OPENERS = { ["function"] = true, ["if"] = true, ["for"] = true, ["while"] = true }

local function findBodyEnd(text, fromPos)
	local depth = 0
	local pos = fromPos
	local started = false
	while true do
		local s, e, word = string.find(text, "([%a_][%w_]*)", pos)
		if not s then
			return #text
		end
		if OPENERS[word] then
			depth += 1
			started = true
		elseif word == "end" then
			depth -= 1
			if started and depth <= 0 then
				return e
			end
		end
		pos = e + 1
	end
end

-- Un mot existe-t-il (en tant que token entier) dans une chaine ?
local function hasWord(s, word)
	return string.find(s, "%f[%w_]" .. escapePattern(word) .. "%f[^%w_]") ~= nil
end

local function containsAny(s, list)
	for _, token in list do
		if string.find(s, token) then
			return true
		end
	end
	return false
end

--==========================================================================
--  ANALYSEUR — listes de detection
--==========================================================================

-- Tokens qui indiquent qu'une validation est faite sur la meme ligne.
local VALIDATOR_TOKENS = {
	"typeof", "tonumber", "tostring", "assert", "IsA",
	"math%.clamp", "math%.min", "math%.max", "string%.match",
	"==", "~=", "<=", ">=", "<", ">",
}
local VALIDATOR_KEYWORDS = { "if", "assert", "elseif", "and", "or" }

-- Sinks CRITIQUES : etat de jeu / persistance / proprietes sensibles.
local SINKS_CRITICAL = {
	"%.Value", "leaderstats", "%.Health", "%.MaxHealth",
	"SetAsync", "IncrementAsync", "UpdateAsync", "DataStore",
	"%.Position", "%.CFrame", ":PivotTo", "SetPrimaryPartCFrame",
	"%.WalkSpeed", "%.JumpPower", ":Kick", ":LoadCharacter",
	"Cash", "Coins", "Money", "Gold", "Gems", "Points", "Credits", "Cred",
}

-- Sinks ELEVES : manipulation d'instance pilotee par le client.
local SINKS_INSTANCE = {
	":Destroy", "%.Parent%s*=", ":Remove%(", ":ClearAllChildren",
	":SetAttribute", "%.Anchored%s*=", "%.Transparency%s*=",
}

-- Tokens prouvant une forme de rate-limit / cooldown / debounce.
local RATELIMIT_TOKENS = {
	"os%.clock", "tick%(", "os%.time", "DateTime",
	"debounce", "Debounce", "cooldown", "Cooldown",
	"[Rr]ate[Ll]imit", "[Rr]atelimit", "lastFire", "LastFire", "nextFire",
}

--==========================================================================
--  ANALYSEUR — collecte des scripts et remotes
--==========================================================================

local REMOTE_CLASSES = {
	RemoteEvent = true,
	RemoteFunction = true,
	UnreliableRemoteEvent = true,
}

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

local function collectRemotes()
	local remotes = {}
	for _, root in getScanRoots() do
		for _, inst in root:GetDescendants() do
			if REMOTE_CLASSES[inst.ClassName] then
				table.insert(remotes, inst)
			end
		end
	end
	return remotes
end

--==========================================================================
--  ANALYSEUR — coeur : extraire les handlers + appliquer les regles
--==========================================================================

-- Patterns de connexion serveur (inline). cap1 = receveur, cap2 = params.
local EVENT_INLINE = {
	"([%w_%.]+)%.OnServerEvent%s*:%s*[Cc]onnect[Pp]?[Aa]?[Rr]?[Aa]?[Ll]?[Ll]?[Ee]?[Ll]?%s*%(%s*function%s*%(([^)]*)%)",
}
local FUNC_INLINE = {
	"([%w_%.]+)%.OnServerInvoke%s*=%s*function%s*%(([^)]*)%)",
}
-- Forme "handler nomme" (a auditer manuellement).
local EVENT_NAMED = "([%w_%.]+)%.OnServerEvent%s*:%s*[Cc]onnect%s*%(%s*([%a_][%w_%.]*)%s*%)"
local FUNC_NAMED  = "([%w_%.]+)%.OnServerInvoke%s*=%s*([%a_][%w_]*)"

local function lastSegment(path)
	local seg = string.match(path, "([%w_]+)%s*$")
	return seg or path
end

local function splitParams(paramStr)
	local params = {}
	for token in string.gmatch(paramStr, "[^,]+") do
		local clean = string.gsub(token, "%s", "")
		if clean ~= "" then
			table.insert(params, clean)
		end
	end
	return params
end

-- Analyse un script : renvoie une liste de findings + l'ensemble des noms de
-- remotes references comme handler (pour la regle "remote sans handler").
local function analyzeScript(scriptInst, handledRemoteNames, findings)
	local okSrc, src = pcall(function()
		return scriptInst.Source
	end)
	if not okSrc or not src or src == "" then
		return okSrc
	end

	local isLocal = scriptInst:IsA("LocalScript")
	local clean = sanitize(src)
	local lineIndex = buildLineIndex(clean)
	local rawLines = string.split(src, "\n")
	local path = scriptInst:GetFullName()

	local function add(severity, rule, line, title, detail, fix, extra)
		local f = {
			severity = severity,
			rule = rule,
			title = title,
			detail = detail,
			fix = fix,
			scriptInst = scriptInst,
			line = line,
		}
		if extra then
			for k, v in extra do
				f[k] = v
			end
		end
		table.insert(findings, f)
	end

	local scriptHasRateLimit = containsAny(clean, RATELIMIT_TOKENS)
	local foundHandlerHere = false

	-- ---- Handlers inline (OnServerEvent) ---------------------------------
	local function processHandler(receiver, paramStr, bodyStartPos, kind)
		foundHandlerHere = true
		local remoteName = lastSegment(receiver)
		handledRemoteNames[remoteName] = true

		local handlerLine = lineFromPos(lineIndex, bodyStartPos)
		local bodyEnd = findBodyEnd(clean, bodyStartPos)
		local body = string.sub(clean, bodyStartPos, bodyEnd)
		local bodyStartLine = handlerLine

		-- R1 : handler serveur dans un LocalScript => ne s'execute jamais
		if isLocal then
			add("Critical", "R1", handlerLine,
				string.format("Handler serveur dans un LocalScript (%s)", remoteName),
				"OnServerEvent/OnServerInvoke ne se declenche jamais dans un LocalScript. "
					.. "Soit la logique critique tourne cote client (contournable), soit c'est un bug.",
				"Deplace ce handler dans un Script (cote serveur), p.ex. ServerScriptService.")
		end

		local params = splitParams(paramStr)
		-- Le 1er parametre est le Player expediteur ; le reste vient du client.
		local firstParam = params[1]
		local clientParams = {}
		for idx = 2, #params do
			table.insert(clientParams, params[idx])
		end
		local hasVararg = false
		for _, p in params do
			if p == "..." then
				hasVararg = true
			end
		end

		-- Decoupe le corps en lignes avec numero absolu.
		local bodyLines = string.split(body, "\n")

		local function paramValidatedSomewhere(p)
			for _, lineText in bodyLines do
				if hasWord(lineText, p) then
					if containsAny(lineText, VALIDATOR_TOKENS)
						or (function()
							for _, kw in VALIDATOR_KEYWORDS do
								if hasWord(lineText, kw) then
									return true
								end
							end
							return false
						end)() then
						return true
					end
				end
			end
			return false
		end

		-- R2 / R5 : flux d'un param client non valide vers un sink.
		local flaggedParams = {}
		for _, p in clientParams do
			if p == "..." then
				continue
			end
			local validated = paramValidatedSomewhere(p)
			for offset, lineText in bodyLines do
				if hasWord(lineText, p) then
					local absLine = bodyStartLine + (offset - 1)
					if containsAny(lineText, SINKS_CRITICAL) and not validated then
						flaggedParams[p] = true
						add("Critical", "R2", absLine,
							string.format("Valeur client '%s' non validee -> etat de jeu (%s)", p, remoteName),
							"Un argument envoye par le client est utilise directement pour modifier "
								.. "de la monnaie, des stats, une position ou des donnees persistantes, "
								.. "sans aucune validation. Un exploiter peut envoyer n'importe quelle valeur.",
							string.format("Valide AVANT usage : if typeof(%s) ~= 'number' then return end ; "
								.. "puis borne (math.clamp) ou recalcule la valeur cote serveur au lieu de "
								.. "faire confiance a '%s'.", p, p),
								{ fixKind = "guard", fixParam = p, fixGuardType = "number", handlerLine = handlerLine })
						break
					elseif containsAny(lineText, SINKS_INSTANCE) and not validated then
						flaggedParams[p] = true
						add("High", "R5", absLine,
							string.format("Instance pilotee par le client '%s' (%s)", p, remoteName),
							"Le serveur agit sur une Instance fournie par le client (Destroy/Parent/Remove...) "
								.. "sans verifier son type ni la propriete/permission. Un exploiter peut viser "
								.. "n'importe quel objet du jeu.",
							string.format("Verifie : if typeof(%s) ~= 'Instance' or not %s:IsA('...') then return end ; "
								.. "et confirme que le joueur a le droit d'agir sur cet objet.", p, p),
							{ fixKind = "guard", fixParam = p, fixGuardType = "Instance", handlerLine = handlerLine })
						break
					end
				end
			end
		end

		-- R3 : param client utilise sans aucune validation (sans sink evident).
		for _, p in clientParams do
			if p == "..." or flaggedParams[p] then
				continue
			end
			local used = hasWord(body, p)
			if used and not paramValidatedSomewhere(p) then
				add("Medium", "R3", bodyStartLine,
					string.format("Argument client '%s' utilise sans validation (%s)", p, remoteName),
					"Le parametre est consomme sans verification de type ni de plage. "
						.. "Tout ce qui vient du client doit etre traite comme hostile.",
					string.format("Ajoute en debut de handler : if typeof(%s) ~= '<type attendu>' then return end", p),
					{ fixKind = "guard", fixParam = p, fixGuardType = "number", handlerLine = handlerLine })
			end
		end

		if hasVararg then
			add("Medium", "R3", bodyStartLine,
				string.format("Handler en vararg (...) : validation indeterminee (%s)", remoteName),
				"Le handler recoit '...' : impossible de verifier statiquement chaque argument. "
					.. "Assure-toi de valider explicitement chaque valeur recue.",
				"Capture les args nommes (local a, b = ...) puis valide chacun par type et plage.")
		end

		-- R4 : pas de rate-limit / debounce dans tout le script.
		if not scriptHasRateLimit then
			add("Medium", "R4", handlerLine,
				string.format("Aucun rate-limit / debounce detecte (%s)", remoteName),
				"Rien n'empeche un exploiter de spammer ce remote des centaines de fois par seconde "
					.. "(surcharge serveur, duplication d'actions).",
				"Ajoute un cooldown par joueur : memorise os.clock() de la derniere requete et "
					.. "ignore si l'intervalle est trop court.",
				{ fixKind = "cooldown", fixPlayerParam = firstParam, fixRemoteName = remoteName, handlerLine = handlerLine })
		end

		-- R6 : OnServerInvoke doit toujours renvoyer et idealement pcall.
		if kind == "Function" then
			if not hasWord(body, "return") then
				add("Low", "R6", handlerLine,
					string.format("OnServerInvoke sans 'return' clair (%s)", remoteName),
					"Une RemoteFunction qui ne renvoie rien (ou qui yield indefiniment) peut bloquer "
						.. "le client appelant et etre utilisee pour des attaques par blocage.",
					"Renvoie toujours une valeur, et enveloppe la logique risquee dans pcall.")
			end
		end
	end

	-- OnServerEvent inline
	for _, pat in EVENT_INLINE do
		local pos = 1
		while true do
			local s, e, receiver, paramStr = string.find(clean, pat, pos)
			if not s then
				break
			end
			-- bodyStart = position du mot 'function' (pour findBodyEnd)
			local fnPos = string.find(clean, "function", s, true) or s
			processHandler(receiver, paramStr, fnPos, "Event")
			pos = e + 1
		end
	end

	-- OnServerInvoke inline
	for _, pat in FUNC_INLINE do
		local pos = 1
		while true do
			local s, e, receiver, paramStr = string.find(clean, pat, pos)
			if not s then
				break
			end
			local fnPos = string.find(clean, "function", s, true) or s
			processHandler(receiver, paramStr, fnPos, "Function")
			pos = e + 1
		end
	end

	-- R8 : handlers nommes (non inline) -> revue manuelle
	do
		local pos = 1
		while true do
			local s, e, receiver, fnName = string.find(clean, EVENT_NAMED, pos)
			if not s then
				break
			end
			if fnName ~= "function" then
				handledRemoteNames[lastSegment(receiver)] = true
				add("Info", "R8", lineFromPos(lineIndex, s),
					string.format("Handler connecte via fonction nommee '%s' (%s)", fnName, lastSegment(receiver)),
					"Le handler n'est pas inline : l'analyse statique ne peut pas verifier son corps automatiquement.",
					"Verifie manuellement que cette fonction valide tous ses arguments client.")
			end
			pos = e + 1
		end
	end
	do
		local pos = 1
		while true do
			local s, e, receiver, fnName = string.find(clean, FUNC_NAMED, pos)
			if not s then
				break
			end
			if fnName ~= "function" then
				handledRemoteNames[lastSegment(receiver)] = true
				add("Info", "R8", lineFromPos(lineIndex, s),
					string.format("OnServerInvoke = fonction nommee '%s' (%s)", fnName, lastSegment(receiver)),
					"Le handler n'est pas inline : revue manuelle necessaire.",
					"Verifie que la fonction valide ses arguments et renvoie toujours une valeur.")
			end
			pos = e + 1
		end
	end

	return okSrc
end

--==========================================================================
--  ANALYSEUR — passe principale
--==========================================================================

local function runAudit()
	local findings = {}
	local handledRemoteNames = {}
	local scripts = collectScripts()
	local remotes = collectRemotes()

	local readFailures = 0
	for _, s in scripts do
		local ok = analyzeScript(s, handledRemoteNames, findings)
		if ok == false then
			readFailures += 1
		end
	end

	-- R7 : remotes sans aucun handler serveur detecte (surface d'attaque oubliee)
	-- R9 : UnreliableRemoteEvent (a ne pas utiliser pour des changements d'etat)
	for _, remote in remotes do
		if remote.ClassName == "UnreliableRemoteEvent" then
			table.insert(findings, {
				severity = "Info", rule = "R9", line = 1,
				title = string.format("UnreliableRemoteEvent : %s", remote.Name),
				detail = "Les messages peuvent etre perdus ou arriver dans le desordre. A reserver "
					.. "aux donnees non critiques (effets, positions cosmetiques), jamais pour de "
					.. "l'etat de jeu, de la monnaie ou des achats.",
				fix = "Si cet evenement modifie de l'etat important, utilise un RemoteEvent fiable.",
				scriptInst = remote,
			})
		end
		if not handledRemoteNames[remote.Name] and remote.ClassName ~= "UnreliableRemoteEvent" then
			table.insert(findings, {
				severity = "Info", rule = "R7", line = 1,
				title = string.format("Remote sans handler serveur detecte : %s", remote.Name),
				detail = "Aucun OnServerEvent/OnServerInvoke n'a ete trouve pour ce remote. "
					.. "C'est peut-etre normal (client->client) mais souvent un remote oublie : "
					.. "une surface d'attaque inutile que les exploiters peuvent quand meme firer.",
				fix = "Si ce remote n'est plus utilise, supprime-le. Sinon verifie son handler.",
				scriptInst = remote,
			})
		end
	end

	-- Tri par severite (desc) puis par script.
	table.sort(findings, function(a, b)
		local ra, rb = SEVERITY[a.severity].rank, SEVERITY[b.severity].rank
		if ra ~= rb then
			return ra > rb
		end
		return (a.title or "") < (b.title or "")
	end)

	return {
		findings = findings,
		scriptCount = #scripts,
		remoteCount = #remotes,
		readFailures = readFailures,
	}
end

--==========================================================================
--  UI
--==========================================================================

local toolbar = plugin:CreateToolbar("Vitals")
local button = toolbar:CreateButton(
	"Security",
	"Vitals · Security — audite la securite de tes RemoteEvents",
	"rbxasset://textures/AvatarCompatibilityPreviewer/warning.png"
)
button.ClickableWhenViewportHidden = true

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right, false, false, 400, 560, 320, 380
)
local widget = plugin:CreateDockWidgetPluginGui("RemoteSecurityAuditor", widgetInfo)
widget.Title = "Vitals · Security"
widget.Name = "RemoteSecurityAuditor"

local function makeRounded(inst, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 6)
	c.Parent = inst
	return c
end

local function makePadding(inst, p)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, p)
	pad.PaddingRight = UDim.new(0, p)
	pad.PaddingTop = UDim.new(0, p)
	pad.PaddingBottom = UDim.new(0, p)
	pad.Parent = inst
	return pad
end

-- Racine
local root = Instance.new("Frame")
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = col(Enum.StudioStyleGuideColor.MainBackground)
root.BorderSizePixel = 0
root.Parent = widget

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 0)
layout.Parent = root

-- Header
local HEADER_H = 154
local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, HEADER_H)
header.BackgroundColor3 = col(Enum.StudioStyleGuideColor.Titlebar)
header.BorderSizePixel = 0
header.LayoutOrder = 1
header.Parent = root
makePadding(header, 10)

local headerList = Instance.new("UIListLayout")
headerList.Padding = UDim.new(0, 6)
headerList.Parent = header

local scanButton = Instance.new("TextButton")
scanButton.Size = UDim2.new(1, 0, 0, 32)
scanButton.BackgroundColor3 = Color3.fromRGB(52, 120, 246)
scanButton.Text = "  ▶  Lancer l'audit de securite"
scanButton.TextColor3 = Color3.fromRGB(255, 255, 255)
scanButton.Font = Enum.Font.GothamBold
scanButton.TextSize = 14
scanButton.AutoButtonColor = true
scanButton.BorderSizePixel = 0
scanButton.LayoutOrder = 1
scanButton.Parent = header
makeRounded(scanButton, 6)

-- Carte du SCORE DE SECURITE /100
local scoreCard = Instance.new("Frame")
scoreCard.Size = UDim2.new(1, 0, 0, 54)
scoreCard.BackgroundColor3 = col(Enum.StudioStyleGuideColor.Item)
scoreCard.BorderSizePixel = 0
scoreCard.LayoutOrder = 2
scoreCard.Parent = header
makeRounded(scoreCard, 6)
makePadding(scoreCard, 9)

local scoreNum = Instance.new("TextLabel")
scoreNum.Size = UDim2.new(0, 62, 1, 0)
scoreNum.BackgroundTransparency = 1
scoreNum.Text = "—"
scoreNum.Font = Enum.Font.GothamBold
scoreNum.TextSize = 30
scoreNum.TextXAlignment = Enum.TextXAlignment.Left
scoreNum.TextColor3 = col(Enum.StudioStyleGuideColor.DimmedText)
scoreNum.Parent = scoreCard

local scoreVerdict = Instance.new("TextLabel")
scoreVerdict.Position = UDim2.new(0, 68, 0, 0)
scoreVerdict.Size = UDim2.new(1, -68, 0, 18)
scoreVerdict.BackgroundTransparency = 1
scoreVerdict.Text = "Score de securite — lance un audit"
scoreVerdict.Font = Enum.Font.GothamMedium
scoreVerdict.TextSize = 13
scoreVerdict.TextXAlignment = Enum.TextXAlignment.Left
scoreVerdict.TextColor3 = col(Enum.StudioStyleGuideColor.MainText)
scoreVerdict.Parent = scoreCard

local gaugeBg = Instance.new("Frame")
gaugeBg.Position = UDim2.new(0, 68, 0, 24)
gaugeBg.Size = UDim2.new(1, -68, 0, 11)
gaugeBg.BackgroundColor3 = col(Enum.StudioStyleGuideColor.Border)
gaugeBg.BorderSizePixel = 0
gaugeBg.Parent = scoreCard
makeRounded(gaugeBg, 5)

local gaugeFill = Instance.new("Frame")
gaugeFill.Size = UDim2.new(0, 0, 1, 0)
gaugeFill.BackgroundColor3 = Color3.fromRGB(120, 130, 138)
gaugeFill.BorderSizePixel = 0
gaugeFill.Parent = gaugeBg
makeRounded(gaugeFill, 5)

local function setScore(score)
	if score == nil then
		scoreNum.Text = "—"
		scoreNum.TextColor3 = col(Enum.StudioStyleGuideColor.DimmedText)
		scoreVerdict.Text = "Score de securite — lance un audit"
		gaugeFill:TweenSize(UDim2.new(0, 0, 1, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.3, true)
		return
	end
	local color, verdict
	if score >= 85 then
		color, verdict = Color3.fromRGB(40, 180, 99), "Solide"
	elseif score >= 60 then
		color, verdict = Color3.fromRGB(240, 180, 0), "Correct"
	elseif score >= 35 then
		color, verdict = Color3.fromRGB(255, 128, 0), "Fragile"
	else
		color, verdict = Color3.fromRGB(220, 53, 69), "A risque"
	end
	scoreNum.Text = tostring(score)
	scoreNum.TextColor3 = color
	scoreVerdict.Text = string.format("Score de securite : %s", verdict)
	gaugeFill.BackgroundColor3 = color
	gaugeFill:TweenSize(UDim2.new(score / 100, 0, 1, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quad, 0.4, true)
end

local summary = Instance.new("TextLabel")
summary.Size = UDim2.new(1, 0, 0, 26)
summary.BackgroundTransparency = 1
summary.Text = "Clique pour scanner tes RemoteEvents / RemoteFunctions."
summary.TextColor3 = col(Enum.StudioStyleGuideColor.DimmedText)
summary.TextXAlignment = Enum.TextXAlignment.Left
summary.TextYAlignment = Enum.TextYAlignment.Top
summary.Font = Enum.Font.Gotham
summary.TextSize = 12
summary.TextWrapped = true
summary.LayoutOrder = 3
summary.Parent = header

-- Barre de filtres
local filterBar = Instance.new("Frame")
filterBar.Size = UDim2.new(1, 0, 0, 34)
filterBar.BackgroundColor3 = col(Enum.StudioStyleGuideColor.Titlebar)
filterBar.BorderSizePixel = 0
filterBar.LayoutOrder = 2
filterBar.Parent = root
makePadding(filterBar, 6)

local filterLayout = Instance.new("UIListLayout")
filterLayout.FillDirection = Enum.FillDirection.Horizontal
filterLayout.Padding = UDim.new(0, 4)
filterLayout.VerticalAlignment = Enum.VerticalAlignment.Center
filterLayout.Parent = filterBar

local currentFilter = "All"
local lastResult = nil
local filterButtons = {}
local doScan -- forward declaration (utilise par les boutons quick-fix)

-- Liste scrollable
local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1, 0, 1, -(HEADER_H + 34))
scroll.BackgroundColor3 = col(Enum.StudioStyleGuideColor.MainBackground)
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 8
scroll.CanvasSize = UDim2.new()
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.LayoutOrder = 3
scroll.Parent = root
makePadding(scroll, 8)

local scrollList = Instance.new("UIListLayout")
scrollList.Padding = UDim.new(0, 8)
scrollList.SortOrder = Enum.SortOrder.LayoutOrder
scrollList.Parent = scroll

local function clearChildren(parent)
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

--==========================================================================
--  QUICK-FIX : insere un squelette de validation dans le script (annulable)
--==========================================================================

local function sanitizeIdent(s)
	return (tostring(s):gsub("%W", "_"))
end

-- Trouve, a partir de la ligne du handler, la 1re ligne contenant ')' (fin de
-- la signature, meme si elle s'etale sur plusieurs lignes). Renvoie l'index.
local function findSignatureEnd(lines, handlerLine)
	for i = handlerLine, math.min(#lines, handlerLine + 8) do
		if string.find(lines[i] or "", ")", 1, true) then
			return i
		end
	end
	return handlerLine
end

-- Renvoie true si applique, false + message sinon.
local function applyFix(finding)
	local inst = finding.scriptInst
	if not inst or not inst:IsA("LuaSourceContainer") then
		return false, "Cible invalide."
	end
	if not finding.fixKind or not finding.handlerLine then
		return false, "Pas de correction automatique pour cette alerte."
	end

	local okRead, src = pcall(function()
		return inst.Source
	end)
	if not okRead or not src then
		return false, "Lecture du script impossible (permission « Injection de script » ?)."
	end

	local lines = string.split(src, "\n")
	local hLine = math.clamp(finding.handlerLine, 1, #lines)
	local indent = string.match(lines[hLine] or "", "^%s*") or ""
	local sigEnd = findSignatureEnd(lines, hLine)

	if finding.fixKind == "guard" then
		local p = finding.fixParam
		if not p or p == "" then
			return false, "Parametre introuvable."
		end
		local ty = finding.fixGuardType or "number"
		local guard = string.format(
			'%s\tif typeof(%s) ~= "%s" then return end -- [Remote Auditor] TODO: ajuste le type/plage attendu',
			indent, p, ty
		)
		table.insert(lines, sigEnd + 1, guard)

	elseif finding.fixKind == "cooldown" then
		local pp = finding.fixPlayerParam
		if not pp or pp == "" or pp == "..." then
			return false, "Nom du parametre Player introuvable : ajoute le cooldown a la main."
		end
		local tbl = "__raCD_" .. sanitizeIdent(finding.fixRemoteName or "remote")
		local check = string.format(
			'%s\tdo local __n = os.clock() if %s[%s] and __n - %s[%s] < 0.5 then return end %s[%s] = __n end -- [Remote Auditor] anti-spam (0.5s)',
			indent, tbl, pp, tbl, pp, tbl, pp
		)
		-- Insere d'abord le check (apres la signature), puis la declaration de la
		-- table AVANT le handler (l'ordre evite de decaler les index).
		table.insert(lines, sigEnd + 1, check)
		table.insert(lines, hLine, string.format(
			'%slocal %s = {} -- [Remote Auditor] cooldown par joueur',
			indent, tbl
		))
	else
		return false, "Type de correction inconnu."
	end

	local newSrc = table.concat(lines, "\n")
	local okWrite = pcall(function()
		ChangeHistoryService:SetWaypoint("Avant Remote Auditor : correction")
		inst.Source = newSrc
		ChangeHistoryService:SetWaypoint("Remote Auditor : validation ajoutee")
	end)
	if not okWrite then
		return false, "Ecriture impossible (autorise la permission « Injection de script »)."
	end
	return true, "Validation inseree. (Ctrl+Z pour annuler.)"
end

-- Carte d'un finding
local function makeCard(finding, order)
	local sev = SEVERITY[finding.severity]

	local card = Instance.new("TextButton")
	card.Size = UDim2.new(1, 0, 0, 0)
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.BackgroundColor3 = col(Enum.StudioStyleGuideColor.Item)
	card.AutoButtonColor = false
	card.Text = ""
	card.BorderSizePixel = 0
	card.LayoutOrder = order
	card.Parent = scroll
	makeRounded(card, 6)
	makePadding(card, 10)

	-- barre de couleur a gauche
	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(0, 4, 1, 0)
	bar.Position = UDim2.new(0, -10, 0, 0)
	bar.BackgroundColor3 = sev.color
	bar.BorderSizePixel = 0
	bar.Parent = card
	makeRounded(bar, 2)

	local cardList = Instance.new("UIListLayout")
	cardList.Padding = UDim.new(0, 4)
	cardList.SortOrder = Enum.SortOrder.LayoutOrder
	cardList.Parent = card

	-- Ligne tag + titre
	local tag = Instance.new("TextLabel")
	tag.Size = UDim2.new(1, 0, 0, 16)
	tag.BackgroundTransparency = 1
	tag.RichText = true
	tag.Text = string.format(
		'<font color="#%s"><b>● %s</b></font>  <font color="#888888">%s</font>',
		sev.color:ToHex(), sev.label, finding.rule
	)
	tag.TextColor3 = col(Enum.StudioStyleGuideColor.MainText)
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
	title.TextColor3 = col(Enum.StudioStyleGuideColor.MainText)
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
	detail.TextColor3 = col(Enum.StudioStyleGuideColor.DimmedText)
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
	fix.TextColor3 = col(Enum.StudioStyleGuideColor.DimmedText)
	fix.TextXAlignment = Enum.TextXAlignment.Left
	fix.TextWrapped = true
	fix.Font = Enum.Font.Gotham
	fix.TextSize = 12
	fix.LayoutOrder = 4
	fix.Parent = card

	local loc = Instance.new("TextLabel")
	loc.Size = UDim2.new(1, 0, 0, 16)
	loc.BackgroundTransparency = 1
	local locText = "—"
	if finding.scriptInst then
		locText = finding.scriptInst:GetFullName()
		if finding.scriptInst:IsA("LuaSourceContainer") and finding.line then
			locText ..= ":" .. tostring(finding.line)
		end
	end
	loc.Text = "📄 " .. locText .. "   (clic pour ouvrir)"
	loc.TextColor3 = Color3.fromRGB(120, 160, 235)
	loc.TextXAlignment = Enum.TextXAlignment.Left
	loc.TextTruncate = Enum.TextTruncate.AtEnd
	loc.Font = Enum.Font.RobotoMono
	loc.TextSize = 11
	loc.LayoutOrder = 5
	loc.Parent = card

	-- Bouton QUICK-FIX (uniquement si une correction auto est disponible)
	if finding.fixKind then
		local fixBtn = Instance.new("TextButton")
		fixBtn.AutomaticSize = Enum.AutomaticSize.X
		fixBtn.Size = UDim2.new(0, 0, 0, 24)
		fixBtn.BackgroundColor3 = Color3.fromRGB(40, 167, 89)
		fixBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		fixBtn.Text = (finding.fixKind == "cooldown")
			and "  🔧 Inserer un anti-spam  "
			or "  🔧 Inserer la validation  "
		fixBtn.Font = Enum.Font.GothamBold
		fixBtn.TextSize = 12
		fixBtn.BorderSizePixel = 0
		fixBtn.AutoButtonColor = true
		fixBtn.LayoutOrder = 6
		fixBtn.Parent = card
		makeRounded(fixBtn, 5)

		fixBtn.MouseButton1Click:Connect(function()
			fixBtn.Active = false
			fixBtn.Text = "  ⏳ ...  "
			local ok, msg = applyFix(finding)
			if ok then
				-- Re-scan : l'alerte disparait et le score remonte.
				if doScan then
					doScan()
				end
			else
				fixBtn.Active = true
				fixBtn.Text = "  ⚠ Echec  "
				summary.Text = "Quick-fix : " .. tostring(msg)
				summary.TextColor3 = SEVERITY.Critical.color
			end
		end)
	end

	card.MouseButton1Click:Connect(function()
		local inst = finding.scriptInst
		if not inst then
			return
		end
		Selection:Set({ inst })
		if inst:IsA("LuaSourceContainer") then
			pcall(function()
				plugin:OpenScript(inst, finding.line or 1)
			end)
		end
	end)

	return card
end

local function render()
	clearChildren(scroll)
	if not lastResult then
		return
	end
	local shown = 0
	local order = 0
	for _, finding in lastResult.findings do
		if currentFilter == "All" or finding.severity == currentFilter then
			order += 1
			makeCard(finding, order)
			shown += 1
		end
	end
	if shown == 0 then
		local empty = Instance.new("TextLabel")
		empty.Size = UDim2.new(1, 0, 0, 40)
		empty.BackgroundTransparency = 1
		empty.Text = (#lastResult.findings == 0)
			and "✅ Aucun probleme detecte. (Pense quand meme a une revue manuelle.)"
			or "Aucun resultat pour ce filtre."
		empty.TextColor3 = col(Enum.StudioStyleGuideColor.DimmedText)
		empty.TextWrapped = true
		empty.Font = Enum.Font.Gotham
		empty.TextSize = 13
		empty.Parent = scroll
	end
end

-- Construit les boutons de filtre une fois qu'on a un resultat (avec compteurs)
local function buildFilters()
	clearChildren(filterBar)
	table.clear(filterButtons)
	local counts = { All = 0 }
	for sevName in SEVERITY do
		counts[sevName] = 0
	end
	if lastResult then
		for _, f in lastResult.findings do
			counts[f.severity] += 1
			counts.All += 1
		end
	end

	local order = { "All", "Critical", "High", "Medium", "Low", "Info" }
	for i, key in order do
		local cnt = counts[key] or 0
		local b = Instance.new("TextButton")
		b.AutomaticSize = Enum.AutomaticSize.X
		b.Size = UDim2.new(0, 0, 1, 0)
		b.BackgroundColor3 = (key == currentFilter)
			and Color3.fromRGB(52, 120, 246)
			or col(Enum.StudioStyleGuideColor.Button)
		b.TextColor3 = (key == currentFilter)
			and Color3.fromRGB(255, 255, 255)
			or col(Enum.StudioStyleGuideColor.ButtonText)
		local labelTxt = (key == "All") and "Tous" or SEVERITY[key].label
		b.Text = string.format("  %s %d  ", labelTxt, cnt)
		b.Font = Enum.Font.GothamMedium
		b.TextSize = 11
		b.BorderSizePixel = 0
		b.LayoutOrder = i
		b.Parent = filterBar
		makeRounded(b, 5)
		b.MouseButton1Click:Connect(function()
			currentFilter = key
			buildFilters()
			render()
		end)
		filterButtons[key] = b
	end
end

-- Penalites par sevedrite pour le score /100.
local SCORE_PENALTY = { Critical = 25, High = 12, Medium = 5, Low = 2, Info = 0 }

local function computeScore(result)
	if result.remoteCount == 0 then
		return nil -- pas de remote a auditer
	end
	local penalty = 0
	for _, f in result.findings do
		penalty += (SCORE_PENALTY[f.severity] or 0)
	end
	return math.clamp(100 - penalty, 0, 100)
end

doScan = function()
	scanButton.Text = "  ⏳  Analyse en cours..."
	scanButton.Active = false
	-- Laisse l'UI se rafraichir avant le travail lourd.
	task.wait()

	local okRun, result = pcall(runAudit)
	scanButton.Text = "  ▶  Relancer l'audit"
	scanButton.Active = true

	if not okRun then
		summary.Text = "Erreur pendant l'audit : " .. tostring(result)
		summary.TextColor3 = SEVERITY.Critical.color
		return
	end

	lastResult = result
	currentFilter = "All"

	setScore(computeScore(result))

	local crit, high = 0, 0
	for _, f in result.findings do
		if f.severity == "Critical" then crit += 1 end
		if f.severity == "High" then high += 1 end
	end

	local msg = string.format(
		"%d scripts • %d remotes • %d alertes (%d critiques, %d elevees)",
		result.scriptCount, result.remoteCount, #result.findings, crit, high
	)
	if result.readFailures > 0 then
		msg ..= string.format(
			"\n⚠ %d script(s) illisibles : autorise la permission « Injection de script » du plugin.",
			result.readFailures
		)
	end
	summary.Text = msg
	summary.TextColor3 = (crit > 0) and SEVERITY.Critical.color
		or (high > 0) and SEVERITY.High.color
		or col(Enum.StudioStyleGuideColor.DimmedText)

	buildFilters()
	render()
end

scanButton.MouseButton1Click:Connect(doScan)

button.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	button:SetActive(widget.Enabled)
end)

button:SetActive(widget.Enabled)
