print("[Bomb Recolor] loading...")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local AssetService = game:GetService("AssetService")
local LocalPlayer = Players.LocalPlayer

-- SETTINGS
local MAX_TEX = 512              -- texture size used for the repaint (384 = lighter, 512 = sharper)
local BUDGET_BACKGROUND = 0.006  -- seconds of each frame used while quietly pre-building colours
local BUDGET_WAITING = 0.03      -- if you click a colour that isn't ready yet, it gets most of the frame
local BOMB_RADIUS = 100          -- studs from you within which a bomb that isn't in your character counts as yours
local BOMB_SCAN_DELAY = 3        -- seconds after loading before the game is searched for bombs to pre-build their colours
-- Extra names to look for (copy the exact name you see in Dex). Spaces / _ / - and capitals are ignored.
-- The prank bomb emote is called "FakeBomb" so that is built in.
local BOMB_NAMES = { gold = {}, prank = { "fakebomb" } }
-- set to true, then use an emote: the F9 console prints every new object that appears near you,
-- so you can read a bomb's real name and add it to BOMB_NAMES above
local BOMB_DEBUG = false

local BUBBLY_FONT = Enum.Font.GothamBold
local MENU_OUTLINE = Color3.fromRGB(70, 74, 88)
local BUTTON_OUTLINE = Color3.fromRGB(120, 125, 142)
local BUTTON_SELECTED = Color3.fromRGB(0, 150, 235)

-- THE COLOURS. Each one FULLY repaints the bomb's texture in that colour: dark parts of the texture become a deep
-- shade of the colour, bright parts a light shade of it, so the detail stays but none of the old colour is left.
-- "ramp" (optional) = exact dark -> bright colours for the repaint.
local COLORS = {
	{ name = "Red",    color = Color3.fromRGB(255, 0, 0) },
	{ name = "Orange", color = Color3.fromRGB(255, 128, 0) },
	{ name = "Green",  color = Color3.fromRGB(0, 255, 0) },
	{ name = "Purple", color = Color3.fromRGB(160, 32, 240) },
	{ name = "Pink",   color = Color3.fromRGB(255, 105, 180),
		ramp = { { 175, 40, 108 }, { 235, 78, 148 }, { 255, 105, 180 }, { 255, 160, 208 }, { 255, 215, 236 } } },
	{ name = "Black",  color = Color3.fromRGB(0, 0, 0),
		ramp = { { 6, 6, 8 }, { 22, 22, 26 }, { 40, 40, 46 }, { 66, 66, 74 }, { 100, 100, 110 } } },
	{ name = "White",  color = Color3.fromRGB(238, 238, 244),
		ramp = { { 188, 188, 198 }, { 216, 216, 225 }, { 238, 238, 244 }, { 249, 249, 253 }, { 255, 255, 255 } } },
}

local env = (getgenv and getgenv()) or _G
-- every repainted image is kept alive here so the recolours keep working after the script is closed
local KEEP = env.BombRecolorKeep or {}
env.BombRecolorKeep = KEEP
if env.BombRecolorCleanup then
	pcall(env.BombRecolorCleanup)
end

local conns = {}
local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(conns, c)
	return c
end

local gui, noteLabel
local function setNote(text)
	if noteLabel then noteLabel.Text = text or "" end
end

local function colorsClose(a, b)
	return math.abs(a.R - b.R) < 0.01 and math.abs(a.G - b.G) < 0.01 and math.abs(a.B - b.B) < 0.01
end

local function isEffect(inst)
	return inst:IsA("Beam") or inst:IsA("Trail") or inst:IsA("ParticleEmitter")
end

local function characterOf(inst)
	local m = inst:FindFirstAncestorOfClass("Model")
	while m do
		if m:FindFirstChildOfClass("Humanoid") then return m end
		m = m:FindFirstAncestorOfClass("Model")
	end
	return nil
end

---------------------------------------------------------------------
-- TEXTURE ENGINE (editable images, same idea as the scopes)
---------------------------------------------------------------------
local TEX_STYLES = {}      -- style name -> function(stats) -> function(lum) -> r, g, b
local texCache = {}        -- "style|texture id" -> { state, image, waiters }
local sources = {}         -- texture id -> { w, h, buf, lum, hist, seen }
local jobs = {}
local working = false

local function buildRamp(stops)
	local R, G, B = {}, {}, {}
	for k = 1, 256 do
		local pos = ((k - 1) / 255) * (#stops - 1)
		local i = math.min(math.floor(pos) + 1, #stops - 1)
		local f = pos - (i - 1)
		local a, b = stops[i], stops[i + 1]
		R[k] = a[1] + (b[1] - a[1]) * f
		G[k] = a[2] + (b[2] - a[2]) * f
		B[k] = a[3] + (b[3] - a[3]) * f
	end
	return R, G, B
end

local function makeStyle(entry)
	local stops = entry.ramp
	if not stops then
		local c = entry.color
		local r, g, b = c.R * 255, c.G * 255, c.B * 255
		local function mul(f) return { r * f, g * f, b * f } end
		local function lift(f) return { r + (255 - r) * f, g + (255 - g) * f, b + (255 - b) * f } end
		stops = { mul(0.3), mul(0.62), { r, g, b }, lift(0.3), lift(0.55) }
	end
	local R, G, B = buildRamp(stops)
	return function(stats)
		local lo, hi = stats.q(0.03), stats.q(0.97)
		local span = math.max(hi - lo, 0.05)
		local floor = math.floor
		return function(lum)
			local rel = (lum - lo) / span
			if rel < 0 then rel = 0 elseif rel > 1 then rel = 1 end
			local k = floor((0.12 + 0.88 * rel) * 255) + 1
			return R[k], G[k], B[k]
		end
	end
end

for _, e in ipairs(COLORS) do
	TEX_STYLES["bomb_" .. e.name] = makeStyle(e)
end

local function percentileOf(hist, total, p)
	if total == 0 then return p end
	local target, run = p * total, 0
	for k = 0, 255 do
		run += hist[k]
		if run >= target then return k / 255 end
	end
	return 1
end

local function makeBreather(budgetFn)
	local mark = os.clock()
	return function()
		if os.clock() - mark > budgetFn() then
			task.wait()
			mark = os.clock()
		end
	end
end

-- once per texture: load it, shrink it, work out every pixel's brightness
local function loadSource(tex, budgetFn)
	local ei
	local okLoad, errLoad = pcall(function()
		ei = AssetService:CreateEditableImageAsync(Content.fromUri(tex))
	end)
	if not (okLoad and ei) then return nil, "couldn't load the texture (" .. tostring(errLoad) .. ")" end
	local src
	local okRead, errRead = pcall(function()
		local size = ei.Size
		local sw, sh = size.X, size.Y
		local step = math.max(math.ceil(math.max(sw, sh) / MAX_TEX), 1)
		local w, h = math.max(math.floor(sw / step), 1), math.max(math.floor(sh / step), 1)
		local raw = ei:ReadPixelsBuffer(Vector2.zero, size)
		local readu8, writeu8 = buffer.readu8, buffer.writeu8
		local readu32, writeu32 = buffer.readu32, buffer.writeu32
		local breathe = makeBreather(budgetFn)
		local buf = raw
		if step > 1 then
			buf = buffer.create(w * h * 4)
			for y = 0, h - 1 do
				local srow, drow = y * step * sw, y * w
				for x = 0, w - 1 do
					writeu32(buf, (drow + x) * 4, readu32(raw, (srow + x * step) * 4))
				end
				breathe()
			end
		end
		local lumBuf = buffer.create(w * h)
		local hist, seen = {}, 0
		for k = 0, 255 do hist[k] = 0 end
		for y = 0, h - 1 do
			local row = y * w
			for x = 0, w - 1 do
				local i = row + x
				local o = i * 4
				local l = math.floor(0.299 * readu8(buf, o) + 0.587 * readu8(buf, o + 1) + 0.114 * readu8(buf, o + 2) + 0.5)
				writeu8(lumBuf, i, l)
				if readu8(buf, o + 3) > 10 then
					hist[l] += 1
					seen += 1
				end
			end
			breathe()
		end
		src = { w = w, h = h, buf = buf, lum = lumBuf, hist = hist, seen = seen }
	end)
	pcall(function() ei:Destroy() end)
	if not okRead then return nil, "couldn't read the texture (" .. tostring(errRead) .. ")" end
	return src
end

-- per colour: repaint a copy of the pixels and put them in a fresh small image
local function paintSource(src, makePixel, budgetFn)
	local image
	local ok, err = pcall(function()
		local w, h = src.w, src.h
		local readu8, writeu8 = buffer.readu8, buffer.writeu8
		local breathe = makeBreather(budgetFn)
		local hist, seen = src.hist, src.seen
		local qCache = {}
		local stats = {
			q = function(p)
				local cached = qCache[p]
				if cached then return cached end
				cached = percentileOf(hist, seen, p)
				qCache[p] = cached
				return cached
			end,
		}
		local out = buffer.create(w * h * 4)
		buffer.copy(out, 0, src.buf, 0, w * h * 4) -- keeps the see-through (alpha) values
		local lumBuf = src.lum
		local pixel = makePixel(stats)
		for y = 0, h - 1 do
			local row = y * w
			for x = 0, w - 1 do
				local i = row + x
				local o = i * 4
				local nr, ng, nb = pixel(readu8(lumBuf, i) / 255)
				writeu8(out, o, nr < 0 and 0 or (nr > 255 and 255 or math.floor(nr)))
				writeu8(out, o + 1, ng < 0 and 0 or (ng > 255 and 255 or math.floor(ng)))
				writeu8(out, o + 2, nb < 0 and 0 or (nb > 255 and 255 or math.floor(nb)))
			end
			breathe()
		end
		local img = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), out)
		table.insert(KEEP, img) -- keeps the image alive so the recolour stays after the script is closed
		image = img
	end)
	if not ok then return nil, "couldn't edit the texture (" .. tostring(err) .. ")" end
	return image
end

local function runJobs()
	if working then return end
	working = true
	task.spawn(function()
		while #jobs > 0 do
			-- a colour the player is waiting on always goes first
			local pick = 1
			for i, j in ipairs(jobs) do
				if next(j.entry.waiters) then pick = i break end
			end
			local job = table.remove(jobs, pick)
			local entry = job.entry
			local function budget()
				return next(entry.waiters) and BUDGET_WAITING or BUDGET_BACKGROUND
			end
			local src, why = sources[job.tex], nil
			if not src then
				src, why = loadSource(job.tex, budget)
				if src then sources[job.tex] = src end
			end
			local image
			if src then image, why = paintSource(src, TEX_STYLES[job.style], budget) end
			if image then
				entry.state = "done"
				entry.image = image
			else
				entry.state = "failed"
				entry.at = os.clock()
				entry.why = tostring(why)
				warn("[Bomb Recolor] " .. job.style .. " texture edit failed: " .. tostring(why))
			end
			local hadWaiters = next(entry.waiters) ~= nil
			entry.waiters = {}
			if hadWaiters then
				setNote(image and "" or ("Texture edit failed: " .. tostring(why)))
			end
		end
		working = false
	end)
end

local function ensureTexture(style, tex)
	if not TEX_STYLES[style] then return nil end
	local key = style .. "|" .. tex
	local entry = texCache[key]
	if entry and entry.state == "failed" and os.clock() - (entry.at or 0) > 2 then
		entry = nil
	end
	if entry then return entry end
	entry = { state = "working", waiters = {} }
	texCache[key] = entry
	table.insert(jobs, { style = style, tex = tex, entry = entry })
	runJobs()
	return entry
end

local function styleFor(entry)
	return "bomb_" .. entry.name
end

-- queues every colour for one texture in the background, so picking a colour is instant
local prebuilt = {}
local function prebuildTex(tex)
	if prebuilt[tex] then return end
	prebuilt[tex] = true
	for _, e in ipairs(COLORS) do
		ensureTexture(styleFor(e), tex)
	end
end

---------------------------------------------------------------------
-- BOMBS
---------------------------------------------------------------------
local BOMB_KINDS = { "gold", "prank" }
local bombSel = {}                                         -- kind -> chosen colour entry
local bombTouched = {
	gold = setmetatable({}, { __mode = "k" }),
	prank = setmetatable({}, { __mode = "k" }),
}
local bombButtons = { gold = {}, prank = {} }              -- kind -> { colour name -> button }
local bombOrig = setmetatable({}, { __mode = "k" })        -- inst -> { prop = original value }
local bombGuarded = setmetatable({}, { __mode = "k" })
local bombPartGuard = setmetatable({}, { __mode = "k" })
local bombOwn = setmetatable({}, { __mode = "k" })         -- roots we already decided are yours
local bombScan = { gold = 0, prank = 0 }
local bombSA = setmetatable({}, { __mode = "k" })          -- part -> the SurfaceAppearance we are showing
local bombSAKey = setmetatable({}, { __mode = "k" })       -- part -> which colour that appearance is
local bombSAImg = setmetatable({}, { __mode = "k" })       -- part -> the image it was built from
local bombTex = setmetatable({}, { __mode = "k" })         -- part -> its original texture id
local bombHid = setmetatable({}, { __mode = "k" })         -- part -> the game's own SurfaceAppearance we took off
local bombWait = setmetatable({}, { __mode = "k" })        -- part -> waiting for its repainted texture
local ourSA = setmetatable({}, { __mode = "k" })           -- appearances made by this run of the script
local paintBombInst

local function bset(inst, prop, value)
	local saved = bombOrig[inst]
	if not saved then
		saved = {}
		bombOrig[inst] = saved
	end
	if saved[prop] == nil then
		local ok, v = pcall(function() return inst[prop] end)
		if ok then saved[prop] = v end
	end
	return (pcall(function() inst[prop] = value end))
end

local function norm(s)
	return string.lower((string.gsub(s, "[%s_%-]", "")))
end

local function nameKind(name)
	local n = norm(name)
	for _, kind in ipairs(BOMB_KINDS) do
		for _, w in ipairs(BOMB_NAMES[kind] or {}) do
			local nw = norm(w)
			if nw ~= "" and string.find(n, nw, 1, true) then return kind end
		end
	end
	if string.find(n, "bomb", 1, true) then
		if string.find(n, "prank", 1, true) or string.find(n, "fake", 1, true) then return "prank" end
		if string.find(n, "gold", 1, true) then return "gold" end
	end
	return nil
end

local function isHumanoidModel(inst)
	return inst:IsA("Model") and inst:FindFirstChildOfClass("Humanoid") ~= nil
end

-- walks up from inst looking for a bomb-named parent (never tests a player's own character name)
local function bombKindOf(inst)
	local cur, depth = inst, 0
	while cur and cur ~= Workspace and cur ~= game and depth < 14 do
		if isHumanoidModel(cur) then return nil end
		local k = nameKind(cur.Name)
		if k then return k, cur end
		cur = cur.Parent
		depth += 1
	end
	return nil
end

local function anchorPos(root)
	local ok, pos = pcall(function() return root:GetPivot().Position end)
	if ok and pos then return pos end
	local p = root:FindFirstChildWhichIsA("BasePart", true)
	return p and p.Position or nil
end

local function bombIsYours(root)
	if bombOwn[root] then return true end
	local char = LocalPlayer.Character
	local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
	local mine = (char and root:IsDescendantOf(char)) or (bp and root:IsDescendantOf(bp)) or root:IsDescendantOf(LocalPlayer)
	if not mine then
		local other = characterOf(root)
		if other and other ~= char then return false end
		local rootPart = char and char:FindFirstChild("HumanoidRootPart")
		local pos = anchorPos(root)
		if rootPart and pos and (pos - rootPart.Position).Magnitude > BOMB_RADIUS then return false end
	end
	bombOwn[root] = true
	return true
end

local function guardBombEffect(inst, kind)
	if bombGuarded[inst] then return end
	bombGuarded[inst] = true
	connect(inst:GetPropertyChangedSignal("Color"), function()
		local e = bombSel[kind]
		if not e then return end
		local cur = inst.Color
		if #cur.Keypoints ~= 2 or not colorsClose(cur.Keypoints[1].Value, e.color) then
			bset(inst, "Color", ColorSequence.new(e.color))
		end
	end)
end

-- if the game paints a plain (texture-less) bomb part back to its own colour, paint it again
local function guardBombPart(inst, kind)
	if bombPartGuard[inst] then return end
	bombPartGuard[inst] = true
	connect(inst:GetPropertyChangedSignal("Color"), function()
		local e = bombSel[kind]
		if not e then return end
		if bombTouched[kind][inst] and not colorsClose(inst.Color, e.color) then
			bset(inst, "Color", e.color)
		end
	end)
end

local function ownAppearance(mp)
	for _, c in ipairs(mp:GetChildren()) do
		if c:IsA("SurfaceAppearance") and c.Name ~= "VSBombSurface" then return c end
	end
	return nil
end

-- appearances left on a part by an earlier run of the script (the effect stays after closing) are cleared away
local function purgeStray(mp)
	for _, c in ipairs(mp:GetChildren()) do
		if c.Name == "VSBombSurface" and not ourSA[c] then
			pcall(function() c:Destroy() end)
		end
	end
end

local function destroyBombSA(mp)
	local sa = bombSA[mp]
	if sa then pcall(function() sa:Destroy() end) end
	bombSA[mp] = nil
	bombSAKey[mp] = nil
	bombSAImg[mp] = nil
end

-- shows a repainted image on the mesh. A colour is never edited in place: a different colour gets a brand new
-- appearance, so there is never a stale / flat texture
local function showSA(mp, key, image)
	local sa = bombSA[mp]
	if sa and sa.Parent == mp and bombSAKey[mp] == key and bombSAImg[mp] == image then return true end
	purgeStray(mp)
	destroyBombSA(mp)
	sa = Instance.new("SurfaceAppearance")
	sa.Name = "VSBombSurface"
	local ok = pcall(function()
		sa.ColorMapContent = Content.fromObject(image)
		sa.Color = Color3.new(1, 1, 1) -- white = no tint at all, the repainted image shows exactly as painted
	end)
	if not ok then
		pcall(function() sa:Destroy() end)
		return false
	end
	ourSA[sa] = true
	sa.Parent = mp
	bombSA[mp] = sa
	bombSAKey[mp] = key
	bombSAImg[mp] = image
	return true
end

local function texOf(mp)
	local tex = bombTex[mp]
	if tex then return tex end
	local own = ownAppearance(mp)
	if own then pcall(function() tex = own.ColorMap end) end
	if type(tex) ~= "string" or tex == "" then
		pcall(function() tex = mp.TextureID end)
	end
	if type(tex) ~= "string" or tex == "" then return nil end
	bombTex[mp] = tex
	return tex
end

-- returns "done" (repainted texture showing), "pending" (still building, the bomb keeps its look until it is ready)
-- or "notex" (a plain part with no texture, painted with a flat colour instead)
local function applyShade(mp, entry, kind)
	local tex = texOf(mp)
	if not tex then return "notex" end
	local style = styleFor(entry)
	local ent = ensureTexture(style, tex) -- queued first so the colour you picked is built before the rest
	prebuildTex(tex)
	if ent and ent.state == "done" then
		local own = ownAppearance(mp)
		if own then
			bombHid[mp] = own -- take the game's own appearance off so ours is the only one showing
			own.Parent = nil
		end
		if showSA(mp, style, ent.image) then return "done" end
		texCache[style .. "|" .. tex] = nil -- the image went bad, build it again
		ent = ensureTexture(style, tex)
	end
	if ent and ent.state == "working" then
		ent.waiters[{}] = true -- gives it most of the frame; a dummy key so nothing else gets repainted
		setNote("Building the bomb colour...")
		if not bombWait[mp] then
			bombWait[mp] = true
			task.spawn(function()
				local t0 = os.clock()
				while ent.state == "working" and os.clock() - t0 < 90 do task.wait(0.05) end
				bombWait[mp] = nil
				local e = bombSel[kind]
				if e and mp.Parent and ent.state == "done" then paintBombInst(mp, e, kind) end
			end)
		end
	end
	return "pending"
end

function paintBombInst(inst, entry, kind)
	local color = entry.color
	if inst:IsA("BasePart") then
		bombTouched[kind][inst] = true
		local state = "notex"
		if inst:IsA("MeshPart") then state = applyShade(inst, entry, kind) end
		if state == "done" then
			bset(inst, "Color", Color3.new(1, 1, 1))
		elseif state == "notex" then
			bset(inst, "Color", color)
			guardBombPart(inst, kind)
		end
		return true
	elseif isEffect(inst) then
		bombTouched[kind][inst] = true
		bset(inst, "Color", ColorSequence.new(color))
		guardBombEffect(inst, kind)
		return true
	elseif inst:IsA("SpecialMesh") then
		bombTouched[kind][inst] = true
		bset(inst, "VertexColor", Vector3.new(color.R, color.G, color.B))
		return true
	elseif inst:IsA("SurfaceAppearance") then
		bombTouched[kind][inst] = true -- its MeshPart recolours it
		return true
	elseif inst:IsA("Decal") or inst:IsA("Texture") then
		bombTouched[kind][inst] = true
		bset(inst, "Color3", color)
		return true
	elseif inst:IsA("Light") then
		bombTouched[kind][inst] = true
		bset(inst, "Color", color)
		return true
	elseif inst:IsA("Fire") then
		bombTouched[kind][inst] = true
		bset(inst, "Color", color)
		bset(inst, "SecondaryColor", color)
		return true
	elseif inst:IsA("Smoke") then
		bombTouched[kind][inst] = true
		bset(inst, "Color", color)
		return true
	elseif inst:IsA("Sparkles") then
		bombTouched[kind][inst] = true
		bset(inst, "SparkleColor", color)
		return true
	elseif inst:IsA("Highlight") then
		bombTouched[kind][inst] = true
		bset(inst, "FillColor", color)
		bset(inst, "OutlineColor", color)
		return true
	end
	return false
end

local function restoreBombInst(inst)
	destroyBombSA(inst)
	bombTex[inst] = nil
	local hid = bombHid[inst]
	if hid then
		pcall(function() hid.Parent = inst end)
		bombHid[inst] = nil
	end
	local saved = bombOrig[inst]
	if saved then
		for prop, v in pairs(saved) do
			pcall(function() inst[prop] = v end)
		end
		bombOrig[inst] = nil
	end
	for _, c in ipairs(inst:GetChildren()) do
		if c.Name == "VSBombSurface" then pcall(function() c:Destroy() end) end
	end
end

local function resetBomb(kind)
	bombSel[kind] = nil
	bombScan[kind] += 1 -- cancels any scan still running
	local n = 0
	for inst in pairs(bombTouched[kind]) do
		pcall(restoreBombInst, inst)
		n += 1
	end
	bombTouched[kind] = setmetatable({}, { __mode = "k" })
	-- safety net: anything we saved an original for that still belongs to this bomb gets restored too
	local extra = {}
	for inst in pairs(bombOrig) do
		if bombKindOf(inst) == kind then table.insert(extra, inst) end
	end
	for _, inst in ipairs(extra) do
		pcall(restoreBombInst, inst)
		n += 1
	end
	setNote("Reset " .. kind .. " bomb (" .. n .. " parts restored)")
end

local function isBombRoot(d, kind)
	return nameKind(d.Name) == kind and not isHumanoidModel(d)
end

local function scanBomb(kind, entry)
	bombScan[kind] += 1
	local token = bombScan[kind]
	task.spawn(function()
		local done, found, n = {}, 0, 0
		local function handle(root)
			if done[root] then return end
			done[root] = true
			if not bombIsYours(root) then return end
			found += 1
			paintBombInst(root, entry, kind)
			for _, d in ipairs(root:GetDescendants()) do
				paintBombInst(d, entry, kind)
			end
		end
		local containers = { Workspace }
		local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
		if bp then table.insert(containers, bp) end
		for _, container in ipairs(containers) do
			for _, d in ipairs(container:GetDescendants()) do
				if bombScan[kind] ~= token then return end
				n += 1
				if n % 2500 == 0 then task.wait() end
				if isBombRoot(d, kind) then handle(d) end
			end
		end
		if bombScan[kind] ~= token then return end
		if found == 0 then
			local nice = (kind == "prank") and "prank bomb (FakeBomb)" or "gold bomb"
			setNote("No " .. nice .. " seen yet. It recolours when you use the emote.")
		end
	end)
end

local function applyBomb(kind, entry)
	bombSel[kind] = entry
	scanBomb(kind, entry)
end

local function onBombAdded(d)
	if BOMB_DEBUG then
		task.defer(function()
			local p = d.Parent
			if not p then return end
			local char = LocalPlayer.Character
			if not (p == Workspace or p == char or p:IsA("Backpack")) then return end
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local pos = anchorPos(d)
			if p == Workspace and root and pos and (pos - root.Position).Magnitude > BOMB_RADIUS then return end
			print("[Bomb Recolor] new object: " .. d.ClassName .. "  " .. d:GetFullName())
		end)
	end
	-- a bomb mesh just appeared: build every colour for it in the background so picking one is instant
	if d:IsA("MeshPart") then
		task.defer(function()
			if not d.Parent then return end
			if not bombKindOf(d) then return end
			local tex = texOf(d)
			if tex then prebuildTex(tex) end
		end)
	end
	if not (bombSel.gold or bombSel.prank) then return end
	task.defer(function()
		if not d.Parent then return end
		local kind, root = bombKindOf(d)
		local e = kind and bombSel[kind]
		if not e then return end
		if not bombIsYours(root) then return end
		paintBombInst(d, e, kind)
	end)
end

connect(Workspace.DescendantAdded, onBombAdded)
do
	local function hookBackpack(bp)
		if bp and bp:IsA("Backpack") then connect(bp.DescendantAdded, onBombAdded) end
	end
	hookBackpack(LocalPlayer:FindFirstChildOfClass("Backpack"))
	connect(LocalPlayer.ChildAdded, hookBackpack)
end

-- a few seconds after loading, quietly search the whole game (emote folders in ReplicatedStorage etc.) for bombs
-- and start building their repainted textures, so even the first time you use the emote it is ready
task.delay(BOMB_SCAN_DELAY, function()
	local n = 0
	for _, d in ipairs(game:GetDescendants()) do
		n += 1
		if n % 3000 == 0 then task.wait() end
		if string.find(string.lower(d.Name), "bomb", 1, true) and not isHumanoidModel(d) and nameKind(d.Name) then
			local list = d:GetDescendants()
			table.insert(list, d)
			for _, m in ipairs(list) do
				if m:IsA("MeshPart") then
					local tex = texOf(m)
					if tex then prebuildTex(tex) end
				end
			end
		end
	end
end)

---------------------------------------------------------------------
-- MENU
---------------------------------------------------------------------
local function setOutline(btn, on)
	local stroke = btn:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = on and BUTTON_SELECTED or BUTTON_OUTLINE
		stroke.Thickness = on and 2.5 or 1
		stroke.Transparency = on and 0 or 0.45
	end
end

local function updateStatus()
	for _, kind in ipairs(BOMB_KINDS) do
		for name, btn in pairs(bombButtons[kind]) do
			setOutline(btn, bombSel[kind] ~= nil and bombSel[kind].name == name)
		end
	end
end

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "BombRecolor"
	gui.ResetOnSpawn = false
	local ok = pcall(function()
		gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
	end)
	if not ok or not gui.Parent then
		gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	end

	local function stroked(inst, thickness, transparency)
		local s = Instance.new("UIStroke")
		s.Color = BUTTON_OUTLINE
		s.Thickness = thickness or 1
		s.Transparency = transparency or 0.45
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		s.Parent = inst
		return s
	end

	local function makeButton(parent, order, text, fill, onClick, height)
		local b = Instance.new("TextButton")
		b.LayoutOrder = order
		b.Size = UDim2.new(1, 0, 0, height or 34)
		b.BackgroundColor3 = fill
		b.BorderSizePixel = 0
		b.AutoButtonColor = false
		b.Font = BUBBLY_FONT
		b.TextSize = 14
		b.TextColor3 = Color3.new(1, 1, 1)
		b.TextStrokeColor3 = Color3.new(0, 0, 0)
		b.TextStrokeTransparency = 0.3
		b.Text = text
		b.Parent = parent
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 9)
		stroked(b)
		b.MouseButton1Click:Connect(onClick)
		return b
	end

	local frame = Instance.new("Frame")
	frame.Name = "Main"
	frame.Size = UDim2.new(0, 290, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.Position = UDim2.new(0, 20, 0.2, 0)
	frame.BackgroundColor3 = Color3.fromRGB(14, 15, 20)
	frame.BorderSizePixel = 0
	frame.Active = true
	pcall(function() frame.Draggable = true end)
	frame.Parent = gui
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 16)
	local fs = stroked(frame, 1.5, 0.5)
	fs.Color = MENU_OUTLINE
	local pad = Instance.new("UIPadding", frame)
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 10)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	local list = Instance.new("UIListLayout", frame)
	list.Padding = UDim.new(0, 6)
	list.SortOrder = Enum.SortOrder.LayoutOrder

	-- header
	local header = Instance.new("Frame")
	header.LayoutOrder = 1
	header.Size = UDim2.new(1, 0, 0, 30)
	header.BackgroundTransparency = 1
	header.Parent = frame
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -70, 1, 0)
	title.BackgroundTransparency = 1
	title.Font = BUBBLY_FONT
	title.Text = "BOMB RECOLOR"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextStrokeColor3 = Color3.new(0, 0, 0)
	title.TextStrokeTransparency = 0.3
	title.TextSize = 19
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = header

	local function headerButton(text, xOffset, fill)
		local b = Instance.new("TextButton")
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, xOffset, 0.5, 0)
		b.Size = UDim2.new(0, 28, 0, 28)
		b.BackgroundColor3 = fill
		b.BorderSizePixel = 0
		b.Font = BUBBLY_FONT
		b.TextSize = 18
		b.TextColor3 = Color3.new(1, 1, 1)
		b.Text = text
		b.Parent = header
		Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
		stroked(b)
		return b
	end
	local minBtn = headerButton("-", -34, Color3.fromRGB(38, 40, 54))
	local closeBtn = headerButton("X", 0, Color3.fromRGB(125, 30, 30))

	-- everything under the header lives in "body" so the minimise button can hide it
	local body = Instance.new("Frame")
	body.LayoutOrder = 2
	body.Size = UDim2.new(1, 0, 0, 0)
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.BackgroundTransparency = 1
	body.Parent = frame
	local bodyList = Instance.new("UIListLayout", body)
	bodyList.Padding = UDim.new(0, 6)
	bodyList.SortOrder = Enum.SortOrder.LayoutOrder

	-- tabs
	local tabRow = Instance.new("Frame")
	tabRow.LayoutOrder = 1
	tabRow.Size = UDim2.new(1, 0, 0, 32)
	tabRow.BackgroundTransparency = 1
	tabRow.Parent = body
	local tabLayout = Instance.new("UIListLayout", tabRow)
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 6)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder

	local pages, tabButtons = {}, {}
	local function showTab(kind)
		for key, page in pairs(pages) do
			page.Visible = (key == kind)
		end
		for key, btn in pairs(tabButtons) do
			setOutline(btn, key == kind)
		end
		setNote("")
	end

	local TAB_DEFS = {
		{ "gold", "GOLD BOMB", "RESET GOLD BOMB" },
		{ "prank", "PRANK BOMB", "RESET PRANK BOMB" },
	}
	for i, def in ipairs(TAB_DEFS) do
		local kind = def[1]
		local tb = makeButton(tabRow, i, def[2], Color3.fromRGB(84, 84, 100), function() showTab(kind) end, 32)
		tb.Size = UDim2.new(0.5, -3, 1, 0)
		tabButtons[kind] = tb

		local page = Instance.new("Frame")
		page.LayoutOrder = 2
		page.Size = UDim2.new(1, 0, 0, 0)
		page.AutomaticSize = Enum.AutomaticSize.Y
		page.BackgroundTransparency = 1
		page.Visible = false
		page.Parent = body
		local pl = Instance.new("UIListLayout", page)
		pl.Padding = UDim.new(0, 6)
		pl.SortOrder = Enum.SortOrder.LayoutOrder
		pages[kind] = page

		makeButton(page, 1, def[3], Color3.fromRGB(84, 84, 100), function()
			local okReset, errReset = pcall(resetBomb, kind)
			if not okReset then setNote("Reset error: " .. tostring(errReset)) end
			updateStatus()
		end)
		for j, entry in ipairs(COLORS) do
			local shown = colorsClose(entry.color, Color3.new(0, 0, 0)) and Color3.fromRGB(40, 40, 46) or entry.color
			local btn = makeButton(page, 1 + j, string.upper(entry.name) .. " BOMB", shown, function()
				applyBomb(kind, entry)
				updateStatus()
			end)
			bombButtons[kind][entry.name] = btn
		end
	end

	noteLabel = Instance.new("TextLabel")
	noteLabel.LayoutOrder = 3
	noteLabel.Size = UDim2.new(1, 0, 0, 14)
	noteLabel.BackgroundTransparency = 1
	noteLabel.Font = Enum.Font.Gotham
	noteLabel.TextSize = 11
	noteLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
	noteLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	noteLabel.TextStrokeTransparency = 0.5
	noteLabel.TextXAlignment = Enum.TextXAlignment.Left
	noteLabel.TextWrapped = true
	noteLabel.Text = ""
	noteLabel.Parent = body

	local hint = Instance.new("TextLabel")
	hint.LayoutOrder = 4
	hint.Size = UDim2.new(1, 0, 0, 14)
	hint.BackgroundTransparency = 1
	hint.Font = Enum.Font.Gotham
	hint.TextSize = 11
	hint.TextColor3 = Color3.fromRGB(150, 152, 168)
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.Text = "RightShift = hide / show"
	hint.Parent = body

	local credit = Instance.new("TextLabel")
	credit.LayoutOrder = 5
	credit.Size = UDim2.new(1, 0, 0, 26)
	credit.BackgroundTransparency = 1
	credit.Font = BUBBLY_FONT
	credit.TextSize = 17
	credit.TextColor3 = Color3.new(1, 1, 1)
	credit.TextStrokeColor3 = Color3.new(0, 0, 0)
	credit.TextStrokeTransparency = 0.3
	credit.Text = "made by: FearVesta"
	credit.Parent = body

	minBtn.MouseButton1Click:Connect(function()
		body.Visible = not body.Visible
		minBtn.Text = body.Visible and "-" or "+"
	end)
	closeBtn.MouseButton1Click:Connect(function()
		if env.BombRecolorCleanup then
			pcall(env.BombRecolorCleanup)
		elseif gui then
			gui:Destroy()
		end
	end)
	connect(UserInputService.InputBegan, function(input, processed)
		if processed then return end
		if input.KeyCode == Enum.KeyCode.RightShift then
			frame.Visible = not frame.Visible
		end
	end)

	showTab("gold")
end

local built, buildErr = pcall(buildGui)
if not built then
	warn("[Bomb Recolor] the menu failed to build: " .. tostring(buildErr))
end

-- closing the script ONLY removes the menu and stops the live watching. Nothing is reset, so every bomb colour
-- you applied stays on the bombs.
env.BombRecolorCleanup = function()
	for _, c in ipairs(conns) do
		pcall(function() c:Disconnect() end)
	end
	if gui then gui:Destroy() end
	env.BombRecolorCleanup = nil
end

print("[Bomb Recolor] loaded")
