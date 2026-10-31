-- love_stub.lua
-- Minimal fake "love" API used to run the real Balatro Lua code headless on Wii.
-- Drawing and audio are no-ops. Threads are emulated with coroutines.
-- Unknown API calls are counted and reported at the end of the run.

local ROOT = rawget(_G, "BALATRO_ROOT") or "sd:/balatro"
local SRC  = ROOT .. "/src/"
local SAVE = ROOT .. "/save/"
local W, H = 640, 480
local gfx = rawget(_G, "gfx")

local unpack = table.unpack or unpack
local loadstring = loadstring or load
local setfenv = setfenv or function(f, env)
  local i = 1
  while true do
    local n = debug.getupvalue(f, i)
    if n == "_ENV" then
      debug.upvaluejoin(f, i, function() return env end, 1)
      break
    elseif not n then
      break
    end
    i = i + 1
  end
  return f
end

local function noop() end

-- ---------------------------------------------------------------------------
-- missing-API tracking
-- ---------------------------------------------------------------------------
local missing = {}
local function strict(tbl, prefix)
  return setmetatable(tbl, {
    __index = function(_, k)
      local key = prefix .. "." .. tostring(k)
      return function()
        missing[key] = (missing[key] or 0) + 1
        return nil
      end
    end
  })
end

local function strict_class(cls, prefix)
  cls.__index = function(_, k)
    local v = rawget(cls, k)
    if v ~= nil then return v end
    if k == "is" then return function() return false end end
    local key = prefix .. ":" .. tostring(k)
    return function()
      missing[key] = (missing[key] or 0) + 1
      return nil
    end
  end
  return cls
end

local now_cache = wii.time()

-- ---------------------------------------------------------------------------
love = {}
love._quit = false
love.getVersion = function() return 11, 5, 0, "Wii" end

love.arg = { parseGameArguments = function() return {} end }

-- ---------------------------------------------------------------------------
-- system
-- ---------------------------------------------------------------------------
love.system = strict({
  getOS = function() return "Nintendo Switch" end,
  openURL = noop,
  getClipboardText = function() return "" end,
  setClipboardText = noop,
  getProcessorCount = function() return 1 end,
}, "love.system")

-- ---------------------------------------------------------------------------
-- timer
-- ---------------------------------------------------------------------------
local last_step = wii.time()
local fps_t, fps_n, fps_v = last_step, 0, 0
local sleep_calls = 0
love.timer = strict({
  getTime = function() return wii.time() end,
  step = function()
    local t = wii.time()
    now_cache = t
    local dt = t - last_step
    last_step = t
    fps_n = fps_n + 1
    if t - fps_t >= 1 then
      fps_v = fps_n / (t - fps_t)
      fps_n = 0
      fps_t = t
    end
    sleep_calls = 0
    return dt
  end,
  getDelta = function() return 0.016 end,
  getFPS = function() return math.floor(fps_v + 0.5) end,
  sleep = function()
    sleep_calls = sleep_calls + 1
    if sleep_calls > 50000 then
      error("love.timer.sleep called 50000 times without a frame step (waiting loop?)")
    end
    love.thread._run_all()
  end,
}, "love.timer")

-- ---------------------------------------------------------------------------
-- filesystem (SD card)
-- ---------------------------------------------------------------------------
local function mkdir_p(path)
  -- path like "sd:/balatro/save/1/sub"; create each level
  local prefix, rest = path:match("^(%a+:/)(.*)$")
  if not prefix then prefix, rest = path:match("^(/)(.*)$") end
  if not prefix then return end
  local cur = prefix:sub(1, -2)
  for part in rest:gmatch("[^/]+") do
    cur = cur .. "/" .. part
    wii.mkdir(cur)
  end
end

local function parent_dir(path)
  return path:match("^(.*)/[^/]*$")
end

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local fs = {}
function fs.getInfo(p, filter)
  p = p or ""
  local t, size = wii.stat(SAVE .. p)
  if not t then t, size = wii.stat(SRC .. p) end
  if not t then return nil end
  if filter and filter ~= t then return nil end
  return { type = t, size = size }
end
function fs.read(p)
  local s = read_all(SAVE .. p) or read_all(SRC .. p)
  if not s then return nil, "Could not open file " .. tostring(p) end
  return s, #s
end
function fs.write(p, data)
  mkdir_p(parent_dir(SAVE .. p))
  local f = io.open(SAVE .. p, "wb")
  if not f then return false, "write failed" end
  f:write(data)
  f:close()
  return true
end
function fs.append(p, data)
  mkdir_p(parent_dir(SAVE .. p))
  local f = io.open(SAVE .. p, "ab")
  if not f then return false, "append failed" end
  f:write(data)
  f:close()
  return true
end
function fs.createDirectory(p)
  mkdir_p(SAVE .. p)
  return true
end
function fs.remove(p)
  local ok = os.remove(SAVE .. p)
  return ok and true or false
end
function fs.getDirectoryItems(p)
  local seen, out = {}, {}
  for _, base in ipairs({ SAVE, SRC }) do
    local list = wii.listdir(base .. p)
    if list then
      for _, name in ipairs(list) do
        if not seen[name] then
          seen[name] = true
          out[#out + 1] = name
        end
      end
    end
  end
  table.sort(out)
  return out
end
function fs.load(p)
  local path = (wii.stat(SAVE .. p) and SAVE or SRC) .. p
  return loadfile(path)
end
fs.getSourceBaseDirectory = function() return ROOT end
fs.getSaveDirectory = function() return SAVE end
fs.getIdentity = function() return "balatro" end
fs.setIdentity = noop
love.filesystem = strict(fs, "love.filesystem")

-- ---------------------------------------------------------------------------
-- data (save files are stored uncompressed for now)
-- ---------------------------------------------------------------------------
love.data = strict({
  compress = function(_, _, s) return s end,
  decompress = function(_, _, s) return s end,
}, "love.data")

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------
love.event = strict({
  pump = noop,
  poll = function() return function() return nil end end,
  push = noop,
  quit = function() love._quit = true end,
}, "love.event")
love.handlers = setmetatable({}, { __index = function() return noop end })

-- ---------------------------------------------------------------------------
-- input
-- ---------------------------------------------------------------------------
local mouse_x, mouse_y = W / 2, H / 2
function love._set_mouse(x, y) mouse_x, mouse_y = x, y end
love.mouse = strict({
  setVisible = noop, isVisible = function() return false end,
  getPosition = function() return mouse_x, mouse_y end,
  getX = function() return mouse_x end, getY = function() return mouse_y end,
  setGrabbed = noop, setRelativeMode = noop, setPosition = noop,
  isDown = function() return false end,
}, "love.mouse")
love.touch = strict({ getTouches = function() return {} end }, "love.touch")
love.joystick = strict({
  getJoysticks = function() return {} end,
  loadGamepadMappings = noop,
  getJoystickCount = function() return 0 end,
}, "love.joystick")
love.keyboard = strict({
  isDown = function() return false end,
  setKeyRepeat = noop,
  hasKeyRepeat = function() return false end,
}, "love.keyboard")

-- ---------------------------------------------------------------------------
-- window
-- ---------------------------------------------------------------------------
love.window = strict({
  getMode = function()
    return W, H, { fullscreen = false, fullscreentype = "desktop", vsync = 1, msaa = 0,
                   resizable = false, borderless = false, centered = true, display = 1,
                   minwidth = 1, minheight = 1, highdpi = false, x = 0, y = 0 }
  end,
  setMode = function() return true end,
  updateMode = function() return true end,
  getDesktopDimensions = function() return W, H end,
  getDisplayCount = function() return 1 end,
  getFullscreenModes = function() return { { width = W, height = H } } end,
  toPixels = function(x) return x end,
  fromPixels = function(x) return x end,
  getDPIScale = function() return 1 end,
  getTitle = function() return "Balatro" end,
  setTitle = noop, setIcon = noop,
  isOpen = function() return true end,
  showMessageBox = function() return 1 end,
}, "love.window")

-- ---------------------------------------------------------------------------
-- audio (no sound, but sources "play" for a believable duration)
-- ---------------------------------------------------------------------------
local Source = strict_class({}, "Source")

-- Real sound: the C side (snd) plays the converted WAV files from sd:/balatro/audio/.
-- Without them (or with an old boot.dol) sources still "play" for a believable time.
local AUDIO_DIR = (rawget(_G, "BALATRO_ROOT") or "sd:/balatro") .. "/audio/"
local snd_cache = {}
local function sound_name(path)
  return tostring(path):match("([^/]+)%.%w+$")
end
local function find_sound_name(name)
  local c = snd_cache[name]
  if c == nil then
    c = false
    if rawget(_G, "snd") then
      local id, dur, stream = snd.load(AUDIO_DIR .. name .. ".wav")
      if id then c = { id = id, dur = dur, stream = stream and true or false } end
    end
    snd_cache[name] = c
  end
  return c or nil
end

-- the sound file is opened the first time the sound is played (80 files at start-up cost seconds)
local function resolve_sound(self)
  if self.pending then
    local name = self.pending
    self.pending = false
    local e = find_sound_name(name)
    if e then
      self.sound = e
      self.dur = e.dur
    else
      local _, size = wii.stat(SRC .. self.path)
      size = size or 20000
      self.dur = (self.kind == "stream") and 180 or math.max(0.25, size / 16000)
    end
  end
end

-- Balatro starts ALL its music and ambient loops at once and only changes their volume.
-- Streaming nine files from the SD card is far too much for the Wii, so a long sound only
-- gets a real voice while it is audible; the position is tracked so it joins in at the right spot.
local AUDIBLE = 0.02

local function source_pos(self)
  local p = self.pos + (now_cache - self.ref_t) * self.pitch
  if self.dur > 0 then p = p % self.dur end
  return p
end

local function start_voice(self)
  local offset = self.sound.stream and source_pos(self) or 0
  self.voice = snd.play(self.sound.id, self.vol, self.pitch, self.loop and true or false, offset) or false
  self.sent_vol, self.sent_pitch = self.vol, self.pitch
end

local function stop_voice(self)
  if self.voice then snd.stop(self.voice); self.voice = false end
end

local function source_sync(self)
  if not self.sound or not self.playing then return end
  local audible = self.vol >= AUDIBLE
  if self.voice then
    if self.sound.stream and not audible then
      self.pos = source_pos(self)
      self.ref_t = now_cache
      stop_voice(self)
    elseif self.vol ~= self.sent_vol or self.pitch ~= self.sent_pitch then
      self.sent_vol, self.sent_pitch = self.vol, self.pitch
      if not snd.set(self.voice, self.vol, self.pitch) then self.voice = false end
    end
  elseif audible and self.sound.stream and (self.loop or (now_cache - self.t0) * self.pitch < self.dur) then
    start_voice(self)
  end
end

function Source:play()
  resolve_sound(self)
  self.playing = true
  self.t0 = now_cache
  self.pos = 0
  self.ref_t = now_cache
  if self.sound then
    stop_voice(self)
    if (not self.sound.stream) or self.vol >= AUDIBLE then start_voice(self) end
  end
  return true
end
function Source:stop()
  stop_voice(self)
  self.playing = false
end
function Source:pause() self:stop() end
function Source:isPlaying()
  if self.voice then
    if snd.playing(self.voice) then return true end
    self.voice = false
    self.playing = false
    return false
  end
  if self.playing and not self.loop and (now_cache - self.t0) * self.pitch >= self.dur then
    self.playing = false
  end
  return self.playing
end
function Source:setVolume(v) self.vol = v; source_sync(self) end
function Source:getVolume() return self.vol end
function Source:setPitch(p)
  if p and p > 0.01 and p ~= self.pitch then
    self.pos = self.pos + (now_cache - self.ref_t) * self.pitch
    self.ref_t = now_cache
    self.pitch = p
    source_sync(self)
  end
end
function Source:getPitch() return self.pitch end
function Source:setLooping(b) self.loop = b and true or false end
function Source:isLooping() return self.loop end
function Source:seek() end
function Source:tell() return 0 end
function Source:release() self:stop(); return true end
function Source:getDuration() resolve_sound(self); return self.dur end
function Source:clone()
  return setmetatable({ path = self.path, dur = self.dur, sound = self.sound, vol = 1, pitch = 1,
                        playing = false, t0 = 0, voice = false, loop = false, pending = self.pending,
                        kind = self.kind, pos = 0, ref_t = 0, sent_vol = -1, sent_pitch = -1 }, Source)
end

love.audio = strict({
  newSource = function(path, kind)
    local name = rawget(_G, "snd") and sound_name(path) or nil
    if name then
      return setmetatable({ path = path, dur = 1, sound = false, pending = name, kind = kind, vol = 1, pitch = 1,
                            playing = false, t0 = 0, voice = false, loop = false,
                            pos = 0, ref_t = 0, sent_vol = -1, sent_pitch = -1 }, Source)
    end
    local snd_entry = nil
    local dur
    if snd_entry then
      dur = snd_entry.dur
    else
      local _, size = wii.stat(SRC .. path)
      size = size or 20000
      dur = (kind == "stream") and 180 or math.max(0.25, size / 16000)
    end
    return setmetatable({ path = path, dur = dur, sound = snd_entry or false, vol = 1, pitch = 1,
                          playing = false, t0 = 0, voice = false, loop = false, pending = false, kind = kind,
                          pos = 0, ref_t = 0, sent_vol = -1, sent_pitch = -1 }, Source)
  end,
  play = function(src) if src then src:play() end end,
  stop = function(src) if src then src:stop() end end,
  setVolume = noop,
}, "love.audio")
love.sound = {}

-- ---------------------------------------------------------------------------
-- graphics (everything is a no-op, objects return plausible sizes)
-- ---------------------------------------------------------------------------
local Font = strict_class({}, "Font")
local function new_font(a, b)
  local size = 12
  if type(a) == "number" then size = a elseif type(b) == "number" then size = b end
  return setmetatable({ size = size, lh = 1 }, Font)
end
function Font:getHeight() return self.h or self.size end
function Font:getWidth(s)
  if self.id then return gfx.font_width(self.id, tostring(s)) end
  local best = 0
  for line in tostring(s):gmatch("[^\n]*") do
    if #line > best then best = #line end
  end
  return best * self.size * 0.55
end
function Font:getAscent() return self.asc or self.size * 0.8 end
function Font:getDescent() return -(self.desc or self.size * 0.2) end
function Font:getBaseline() return self.asc or self.size * 0.8 end
function Font:getLineHeight() return self.lh end
function Font:setLineHeight(v) self.lh = v end
function Font:setFilter() end
function Font:getFilter() return "nearest", "nearest" end
function Font:hasGlyphs() return true end
function Font:getDPIScale() return 1 end
function Font:setFallbacks() end
function Font:getWrap(text, limit)
  local function wid(str)
    if self.id then return gfx.font_width(self.id, str) end
    return #str * self.size * 0.55
  end
  local lines, maxw = {}, 0
  for para in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    local cur = ""
    for word in para:gmatch("%S+") do
      local try = (#cur > 0) and (cur .. " " .. word) or word
      if wid(try) > limit and #cur > 0 then
        lines[#lines + 1] = cur
        local w = wid(cur)
        if w > maxw then maxw = w end
        cur = word
      else
        cur = try
      end
    end
    lines[#lines + 1] = cur
    local w = wid(cur)
    if w > maxw then maxw = w end
  end
  return maxw, lines
end

local Text = strict_class({}, "Text")
local function plain(str)
  if type(str) == "table" then
    local parts = {}
    for i = 1, #str do
      if type(str[i]) == "string" then parts[#parts + 1] = str[i]
      elseif type(str[i]) == "number" then parts[#parts + 1] = tostring(str[i]) end
    end
    return table.concat(parts)
  end
  return tostring(str)
end
function Text:set(str)
  local s = plain(str)
  self.str = s
  self.w = self.font:getWidth(s)
  local _, n = s:gsub("\n", "")
  self.h = self.font:getHeight() * (n + 1)
end
function Text:setf(str, limit)
  local s = plain(str)
  self.str = s
  local w, lines = self.font:getWrap(s, limit or 1000)
  self.w = limit or w
  self.h = self.font:getHeight() * math.max(1, #lines)
end
function Text:add(str) self:set(plain(str)); return 1 end
function Text:addf(str, limit) self:setf(str, limit); return 1 end
function Text:clear() self.w, self.h, self.str = 0, 0, "" end
function Text:getWidth() return self.w end
function Text:getHeight() return self.h end
function Text:getDimensions() return self.w, self.h end
function Text:getFont() return self.font end
function Text:setFont(f) self.font = f end

local Image = strict_class({}, "Image")
function Image:getWidth() return self.w / self.dpi end
function Image:getHeight() return self.h / self.dpi end
function Image:getDimensions() return self.w / self.dpi, self.h / self.dpi end
function Image:getPixelWidth() return self.w end
function Image:getPixelHeight() return self.h end
function Image:getPixelDimensions() return self.w, self.h end
function Image:getDPIScale() return self.dpi end
function Image:setFilter() end
function Image:setMipmapFilter() end
function Image:release() return true end

local function png_dims(path)
  local f = io.open(SRC .. path, "rb")
  if not f then return nil end
  local b = f:read(24)
  f:close()
  if not b or #b < 24 then return nil end
  local function u32(i)
    local a, bb, c, d = b:byte(i, i + 3)
    return ((a * 256 + bb) * 256 + c) * 256 + d
  end
  return u32(17), u32(21)
end

-- Read the pixel size from the PNG header. If the 2x file is not on the SD,
-- use the 1x file doubled (and the other way round), so logical sizes stay right.
local function png_size(path)
  local w, h = png_dims(path)
  if w then return w, h end
  local p1, n1 = path:gsub("/2x/", "/1x/")
  if n1 > 0 then
    w, h = png_dims(p1)
    if w then return w * 2, h * 2 end
  end
  local p2, n2 = path:gsub("/1x/", "/2x/")
  if n2 > 0 then
    w, h = png_dims(p2)
    if w then return w / 2, h / 2 end
  end
  return 64, 64
end

local Quad = strict_class({}, "Quad")
function Quad:getViewport() return self.x, self.y, self.w, self.h end
function Quad:setViewport(x, y, w, h) self.x, self.y, self.w, self.h = x, y, w, h end
function Quad:getTextureDimensions() return self.sw, self.sh end

local Canvas = strict_class({}, "Canvas")
function Canvas:getWidth() return self.w end
function Canvas:getHeight() return self.h end
function Canvas:getDimensions() return self.w, self.h end
function Canvas:getPixelWidth() return self.w end
function Canvas:getPixelHeight() return self.h end
function Canvas:getPixelDimensions() return self.w, self.h end
function Canvas:getDPIScale() return 1 end
function Canvas:setFilter() end
function Canvas:release() return true end

local Shader = strict_class({}, "Shader")
function Shader:send(name, v) self.u[name] = v end
function Shader:sendColor(name, v) self.u[name] = v end
function Shader:hasUniform() return false end
function Shader:getWarnings() return "" end

local Video = strict_class({}, "Video")
function Video:play() end
function Video:pause() end
function Video:isPlaying() return false end

local default_font = new_font(12)

-- draw-call counters (to estimate how much the real renderer will have to do)
local draw_count, prim_count = 0, 0
function love._counts()
  local d, p = draw_count, prim_count
  draw_count, prim_count = 0, 0
  return d, p
end

local g = {
  push = noop, pop = noop, translate = noop, scale = noop, rotate = noop,
  origin = noop, shear = noop,
  setColor = noop, getColor = function() return 1, 1, 1, 1 end,
  setBackgroundColor = noop, clear = noop, present = noop,
  draw = function() draw_count = draw_count + 1 end,
  rectangle = function() prim_count = prim_count + 1 end,
  polygon = function() prim_count = prim_count + 1 end,
  line = function() prim_count = prim_count + 1 end,
  circle = function() prim_count = prim_count + 1 end,
  ellipse = function() prim_count = prim_count + 1 end,
  arc = function() prim_count = prim_count + 1 end,
  points = function() prim_count = prim_count + 1 end,
  print = function() prim_count = prim_count + 1 end,
  printf = function() prim_count = prim_count + 1 end,
  setLineWidth = noop, getLineWidth = function() return 1 end, setLineStyle = noop,
  setShader = noop, getShader = function() return nil end,
  setCanvas = noop, getCanvas = function() return nil end,
  setBlendMode = noop, getBlendMode = function() return "alpha", "alphamultiply" end,
  setScissor = noop, getScissor = function() return nil end, intersectScissor = noop,
  setFont = noop, getFont = function() return default_font end,
  setDefaultFilter = noop, getDefaultFilter = function() return "linear", "linear", 1 end,
  setColorMask = noop, reset = noop,
  isActive = function() return true end, isCreated = function() return true end,
  getWidth = function() return W end, getHeight = function() return H end,
  getDimensions = function() return W, H end,
  getPixelWidth = function() return W end, getPixelHeight = function() return H end,
  getDPIScale = function() return 1 end,
  setNewFont = function(a, b) default_font = new_font(a, b); return default_font end,
  newFont = new_font,
  newText = function(font, str)
    local t = setmetatable({ font = font or default_font, w = 0, h = 0 }, Text)
    if str ~= nil then t:set(str) end
    return t
  end,
  newImage = function(path, opts)
    local w, h = png_size(path)
    return setmetatable({ w = w, h = h, dpi = (opts and opts.dpiscale) or 1 }, Image)
  end,
  newQuad = function(x, y, w, h, a, b)
    local sw, sh = a, b
    if type(a) == "table" and a.getDimensions then sw, sh = a:getDimensions() end
    return setmetatable({ x = x, y = y, w = w, h = h, sw = sw, sh = sh }, Quad)
  end,
  newCanvas = function(w, h)
    return setmetatable({ w = w or W, h = h or H }, Canvas)
  end,
  newShader = function(path)
    local name = tostring(path):match("([^/\\]+)%.%w+$") or "unknown"
    return setmetatable({ name = name, u = {} }, Shader)
  end,
  newVideo = function() return setmetatable({}, Video) end,
}
-- ---------------------------------------------------------------------------
-- real drawing through the C module "gfx" (only when running on the Wii renderer)
-- ---------------------------------------------------------------------------
local FORCE_NEAREST = false  -- smooth sampling: the art is drawn smaller than it is (clubs / spades stay readable)
if gfx then
  W, H = gfx.width, gfx.height
  g.push, g.pop, g.origin = gfx.push, gfx.pop, gfx.origin
  g.translate, g.scale, g.rotate = gfx.translate, gfx.scale, gfx.rotate
  g.setLineWidth = gfx.set_line_width

  local cr, cg, cb, ca = 1, 1, 1, 1
  g.setColor = function(r, gr, b, a)
    if type(r) == "table" then r, gr, b, a = r[1], r[2], r[3], r[4] end
    cr, cg, cb, ca = r, gr, b, a or 1
    gfx.set_color(r, gr, b, a)
  end
  local current_shader = nil
  g.setShader = function(sh) current_shader = sh end
  g.clear = function(r, gr, b)
    if type(r) == "table" then gfx.clear(r[1], r[2], r[3])
    else gfx.clear(r, gr, b) end
  end
  g.rectangle = function(mode, x, y, w, h) gfx.rect(mode == "fill", x, y, w, h) end
  g.polygon = function(mode, a, ...)
    if type(a) == "table" then gfx.polygon(mode == "fill", a)
    else gfx.polygon(mode == "fill", { a, ... }) end
  end

  local image_cache = {}   -- path -> { id, pw, ph }: never load the same file twice
  g.newImage = function(path, opts)
    local dpi = (opts and opts.dpiscale) or 1
    if path:find("-logo.png", 1, true) then   -- splash screen logos: not needed
      return setmetatable({ id = 0, w = 64, h = 64, dpi = 1 }, Image)
    end
    -- the high contrast pictures (_opt2) share the normal file, unless the option is on (or is being
    -- switched on right now: play.lua sets WII_REAL_OPT2 while it loads them)
    if not (rawget(_G, "WII_REAL_OPT2") or (rawget(_G, "G") and G.SETTINGS and G.SETTINGS.colourblind_option)) then
      path = path:gsub("_opt2", "")
    end
    local tries = { path }
    local alt, n = path:gsub("/2x/", "/1x/")
    if n > 0 then tries[#tries + 1] = alt end
    for _, p in ipairs(tries) do
      local c = image_cache[p]
      if c == nil then
        local id, pw, ph = gfx.load_image(SRC .. p, FORCE_NEAREST)
        c = id and { id = id, pw = pw, ph = ph } or false
        image_cache[p] = c
      end
      if c then
        -- a 1x file standing in for a 2x request: its pixel size is the 2x logical size
        local d = (p ~= path) and 1 or dpi
        return setmetatable({ id = c.id, w = c.pw, h = c.ph, dpi = d }, Image)
      end
    end
    return setmetatable({ id = 0, w = 64, h = 64, dpi = 1 }, Image)
  end

  -- fonts: the English font is rasterized small by FreeType and scaled back up
  local FONT_RATIO = 0.12
  local function make_font(a, b)
    if type(a) == "string" and a:find("m6x11plus", 1, true) then
      local size = tonumber(b) or 12
      local px = math.max(8, math.min(48, math.floor(size * FONT_RATIO + 0.5)))
      local id, h, asc, desc = gfx.new_font(SRC .. a, size, px)
      if id then
        return setmetatable({ size = size, lh = 1, id = id, h = h, asc = asc, desc = desc }, Font)
      end
    end
    return new_font(a, b)
  end
  g.newFont = make_font
  g.setNewFont = function(a, b) default_font = make_font(a, b); return default_font end

  -- four corner colours that slowly rotate through the background's three colours
  local function gradient_corners(u)
    local cols = {}
    for k = 1, 3 do
      local c = u["colour_" .. k]
      if type(c) == "table" then cols[#cols + 1] = c end
    end
    local n = #cols
    if n == 0 then return nil end
    if n == 1 then cols[2], cols[3], n = cols[1], cols[1], 3 end
    local t = (tonumber(u.time) or 0) * 0.12
    local base = math.floor(t)
    local fr = t - base
    fr = fr * fr * (3 - 2 * fr)
    local out = {}
    for k = 0, 3 do
      local ca = cols[(base + k) % n + 1]
      local cb = cols[(base + k + 1) % n + 1]
      for i = 1, 3 do out[#out + 1] = ca[i] + (cb[i] - ca[i]) * fr end
      out[#out + 1] = 1
    end
    return out
  end

  -- Card editions without shaders: shimmering colour added on top (foil, holo, polychrome),
  -- inverted colours (negative) and a dark red cast (debuffed). They are cheap: one extra picture per edition card.
  local function hue_rgb(h)
    h = h % 1
    local x = h * 6
    local i = math.floor(x)
    local f = x - i
    local q = 1 - f
    if i == 0 then return 1, f, 0 elseif i == 1 then return q, 1, 0 elseif i == 2 then return 0, 1, f
    elseif i == 3 then return 0, q, 1 elseif i == 4 then return f, 0, 1 else return 1, 0, q end
  end
  local SHEEN = (gfx.version or 0) >= 7      -- new boot.dol: coloured sheen; old one: plain shimmer
  local EDITION_FX = {      -- base = always-on glow, strength = how much brighter the sweeping band gets
    foil = { strength = 0.60, base = 0.14, speed = 0.45, color = function() return 0.75, 0.90, 1.0 end },
    holo = { strength = 0.65, base = 0.14, speed = 0.40, color = function(x) return hue_rgb(0.80 + 0.22 * math.sin(6.2832 * x)) end },
    polychrome = { strength = 0.65, base = 0.14, speed = 0.50, color = function(x) return hue_rgb(x) end },
  }
  -- how many effect drawings happen (written to the report every 3 seconds)
  local fx_counts, fx_first = {}, {}
  local function fx_count(name)
    fx_counts[name] = (fx_counts[name] or 0) + 1
    if not fx_first[name] then fx_first[name] = true; wii.log("card effect drawn for the first time: " .. name) end
  end
  function love._fx_report(frames)
    local parts = {}
    for _, name in ipairs({ "foil", "holo", "polychrome", "negative", "debuff" }) do
      local n = fx_counts[name]
      if n then parts[#parts + 1] = string.format("%s %.1f", name, n / math.max(1, frames or 1)) end
    end
    fx_counts = {}
    if #parts == 0 then return nil end
    return table.concat(parts, " | ")
  end

  -- main menu background: a pre-rendered paint swirl picture that turns slowly. One picture per frame
  -- instead of a colour calculation (much cheaper).
  -- Pictures live in sd:/balatro/wii/ : menu_swirl.png (the default) and any number of extra ones
  -- called menu_swirl_1.png, menu_swirl_2.png, menu_swirl_3.png ... (same size as the default).
  -- Which one is used is chosen by the optional text file sd:/balatro/swirl.txt:
  --   (no file / empty / "0" / "default")  -> menu_swirl.png, exactly as before
  --   "random"                              -> a different random one each time the game starts
  --   a number, e.g. "2"                    -> menu_swirl_2.png
  local swirl_img = nil
  do
    local dir = ROOT .. "/wii/"
    local function exists(p)
      local f = io.open(p, "rb")
      if f then f:close(); return true end
      return false
    end
    local default_path = dir .. "menu_swirl.png"
    local pool, names = { default_path }, { "menu_swirl.png" }
    local miss = 0
    for n = 1, 99 do
      local name = "menu_swirl_" .. n .. ".png"
      if exists(dir .. name) then
        pool[#pool + 1] = dir .. name; names[#names + 1] = name; miss = 0
      else
        miss = miss + 1
        if miss >= 3 then break end      -- stop after three missing numbers in a row
      end
    end
    local choice = 1
    local how = "default"
    local f = io.open(ROOT .. "/swirl.txt", "rb")
    if f then
      local txt = (f:read("*a") or ""):lower():gsub("%s+", "")
      f:close()
      if txt == "random" then
        local seedt = math.floor(wii.time() * 1000) + ((os and os.time and os.time()) or 0)
        choice = seedt % #pool + 1
        how = "random"
      elseif tonumber(txt) and tonumber(txt) >= 1 then
        local want = "menu_swirl_" .. math.floor(tonumber(txt)) .. ".png"
        for k = 1, #names do if names[k] == want then choice = k end end
        how = (choice == 1) and "number not found, default used" or "number"
      end
    end
    local ok, id, w, h = pcall(gfx.load_image, pool[choice], false)
    if (not ok or not id) and choice ~= 1 then
      wii.log("swirl picture " .. names[choice] .. " could not be loaded, the default is used")
      ok, id, w, h = pcall(gfx.load_image, default_path, false)
    end
    if ok and id then
      swirl_img = { id = id, w = w, h = h }
      wii.log("main menu swirl: " .. names[choice] .. " (" .. how .. ", " .. #pool .. " available)")
    else
      wii.log("menu_swirl.png not found: the old swirl is used")
    end
  end
  local swirl_logged = false
  local wipe_logged = {}
  g.draw = function(d, a, b, c, e, f, h, i, j)
    local mt = getmetatable(d)
    local sh = current_shader
    if sh and rawget(_G, "G") and G.screenwipe and not wipe_logged[sh.name or "?"] then
      wipe_logged[sh.name or "?"] = true
      wii.log("screen wipe draws with shader " .. tostring(sh.name))
    end
    local override = false
    local fx_active = false

    if sh then
      local nm = sh.name
      if nm == "dissolve" then
        local u = sh.u
        local dis = tonumber(u.dissolve) or 0
        if dis > 1 then dis = 1 end
        if u.shadow then
          gfx.set_color(0, 0, 0, 0.3 * ca * (1 - dis)); override = true
        elseif dis > 0 then
          gfx.set_color(cr, cg, cb, ca * (1 - dis)); override = true
        end
      elseif nm == "background" or nm == "splash" then
        -- the main menu (shader "splash", red and blue) gets a real paint swirl; the game itself
        -- keeps a plain gradient (much cheaper)
        if swirl_img and rawget(_G, "G") and G.STAGES and G.STAGE == G.STAGES.MAIN_MENU and not G.screenwipe then
          local t = wii.time()
          local sc = (800 / swirl_img.w) * (1.07 + 0.03 * math.sin(t * 0.35))
          gfx.set_corner_colors()
          gfx.set_color(1, 1, 1, 1)
          gfx.push()
          gfx.origin()          -- the game draws its background inside a scaled space: use plain screen pixels
          gfx.draw_image(swirl_img.id, 0, 0, swirl_img.w, swirl_img.h, swirl_img.w, swirl_img.h,
                         320, 240, t * 0.10, sc, sc, swirl_img.w / 2, swirl_img.h / 2)
          gfx.pop()
          gfx.set_color(cr, cg, cb, ca)
          if not swirl_logged then swirl_logged = true; wii.log("main menu swirl drawn (picture, shader " .. nm .. ")") end
          return
        end
        if gfx.swirl and rawget(_G, "G") and G.STAGES and G.STAGE == G.STAGES.MAIN_MENU and not G.screenwipe then
          local u = sh.u
          local c1, c2, c3 = u.colour_1, u.colour_2, u.colour_3
          if type(c1) == "table" and type(c2) == "table" then
            if type(c3) ~= "table" then
              c3 = { (c1[1] + c2[1]) * 0.08, (c1[2] + c2[2]) * 0.08, (c1[3] + c2[3]) * 0.08 }
            end
            if not swirl_logged then swirl_logged = true; wii.log("main menu swirl drawn (shader " .. nm .. ")") end
            gfx.swirl(wii.time(), 0.5, 1.3, c1[1], c1[2], c1[3], c2[1], c2[2], c2[3], c3[1], c3[2], c3[3])
            return
          end
        end
        local corners = gradient_corners(sh.u)
        if corners then
          gfx.set_corner_colors(unpack(corners))
          if type(a) == "table" then
            gfx.draw_flat(a.w, a.h, b, c, e or 0, f or 1, h or (f or 1), i or 0, j or 0)
          else
            gfx.draw_flat(d.w / d.dpi, d.h / d.dpi, a, b, c or 0, e or 1, f or (e or 1), h or 0, i or 0)
          end
          gfx.set_corner_colors()
          return
        end
      elseif nm == "flash" or nm == "vortex" or nm == "flame" then
        return   -- effects that only exist as shaders: not drawn
      elseif EDITION_FX[nm] then
        if mt ~= Image or not gfx.set_effect then return end
        local e = EDITION_FX[nm]
        fx_count(nm)
        local now = wii.time()
        local cs = {}
        if SHEEN then
          -- a coloured sheen in the shape of the card: every corner has its own phase, so a bright
          -- band sweeps over the card; polychrome / holo also run through the colours
          for k = 0, 3 do
            local ph = (now * e.speed - k * 0.25) % 1
            local band = math.max(0, math.sin(6.2832 * ph)); band = band * band
            local br = e.base + e.strength * band
            local r, g, b = e.color(now * e.speed * 0.5 + k * 0.25)
            cs[#cs + 1] = r * br; cs[#cs + 1] = g * br; cs[#cs + 1] = b * br; cs[#cs + 1] = 1
          end
          gfx.set_effect(3)
        else
          for k = 0, 3 do
            local x = now * e.speed + k * 0.22
            local br = e.strength * (0.65 + 0.35 * math.sin(6.2832 * x))
            local r, g, b = e.color(x)
            cs[#cs + 1] = r * br; cs[#cs + 1] = g * br; cs[#cs + 1] = b * br; cs[#cs + 1] = 1
          end
          gfx.set_effect(1)
        end
        gfx.set_corner_colors(unpack(cs))
        fx_active = true
      elseif nm == "negative" and gfx.set_effect then
        fx_count("negative")
        gfx.set_effect(2)
        gfx.set_color(0.88, 0.95, 1.0, ca)
        override = true
        fx_active = true
      elseif nm == "debuff" then
        fx_count("debuff")
        gfx.set_color(0.10, 0.02, 0.05, 0.58 * ca)
        override = true
      end
    end

    if mt == Image then
      draw_count = draw_count + 1
      local lw, lh = d.w / d.dpi, d.h / d.dpi
      if type(a) == "table" then
        gfx.draw_image(d.id, a.x, a.y, a.w, a.h, lw, lh, b, c, e or 0, f or 1, h or (f or 1), i or 0, j or 0)
      else
        gfx.draw_image(d.id, 0, 0, lw, lh, lw, lh, a, b, c or 0, e or 1, f or (e or 1), h or 0, i or 0)
      end
    elseif mt == Text then
      if d.font.id and d.str and d.str ~= "" then
        gfx.draw_text(d.font.id, d.str, a, b, c or 0, e or 1, f or (e or 1), h or 0, i or 0)
      end
    end

    if fx_active then gfx.set_corner_colors(); gfx.set_effect(0) end
    if override then gfx.set_color(cr, cg, cb, ca) end
  end
end

love.graphics = strict(g, "love.graphics")

-- ---------------------------------------------------------------------------
-- threads emulated with coroutines (each thread gets its own globals table)
-- ---------------------------------------------------------------------------
local function deepcopy(v, seen)
  if type(v) ~= "table" then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local c = {}
  seen[v] = c
  for k, x in pairs(v) do c[deepcopy(k, seen)] = deepcopy(x, seen) end
  return c
end

local Channel = strict_class({}, "Channel")
function Channel:push(v)
  self.tail = self.tail + 1
  self.q[self.tail] = deepcopy(v)
  return self.tail - self.head + 1
end
function Channel:supply(v) return self:push(v) end
function Channel:pop()
  if self.head > self.tail then return nil end
  local v = self.q[self.head]
  self.q[self.head] = nil
  self.head = self.head + 1
  return v
end
function Channel:peek()
  if self.head > self.tail then return nil end
  return self.q[self.head]
end
function Channel:getCount() return self.tail - self.head + 1 end
function Channel:clear() self.q = {}; self.head = 1; self.tail = 0 end

local current_thread = nil
function Channel:demand()
  while true do
    if self.head <= self.tail then return self:pop() end
    local co, ismain = coroutine.running()
    if co == nil or ismain or current_thread == nil then return nil end
    current_thread.waiting = self
    coroutine.yield()
  end
end

local channels = {}
local threads = {}

local Thread = strict_class({}, "Thread")
function Thread:_resume(...)
  if not self.co or coroutine.status(self.co) ~= "suspended" then return end
  local prev = current_thread
  current_thread = self
  self.waiting = nil
  local ok, err = coroutine.resume(self.co, ...)
  current_thread = prev
  if not ok then
    self.err = tostring(err)
    wii.log("THREAD ERROR (" .. self.name .. "): " .. self.err)
  end
end
function Thread:start(...)
  self.co = coroutine.create(self.fn)
  threads[#threads + 1] = self
  self:_resume(...)
end
function Thread:isRunning()
  return self.co ~= nil and coroutine.status(self.co) ~= "dead"
end
function Thread:getError() return self.err end
function Thread:wait() end

love.thread = strict({
  getChannel = function(name)
    local c = channels[name]
    if not c then
      c = setmetatable({ name = name, q = {}, head = 1, tail = 0 }, Channel)
      channels[name] = c
    end
    return c
  end,
  newChannel = function()
    return setmetatable({ q = {}, head = 1, tail = 0 }, Channel)
  end,
  newThread = function(src)
    local fn, err
    if tostring(src):find("\n", 1, true) then
      fn, err = loadstring(src, "thread")
    else
      fn, err = love.filesystem.load(src)
    end
    if not fn then error("newThread failed: " .. tostring(err)) end
    setfenv(fn, setmetatable({}, { __index = _G }))
    return setmetatable({ fn = fn, name = tostring(src):sub(1, 40) }, Thread)
  end,
  _run_all = function()
    now_cache = wii.time()
    for i = 1, #threads do
      local t = threads[i]
      if t.co and coroutine.status(t.co) == "suspended" then
        local w = t.waiting
        if (not w) or (w.head <= w.tail) then t:_resume() end
      end
    end
  end,
}, "love.thread")

-- ---------------------------------------------------------------------------
-- modules that the game "require"s
-- ---------------------------------------------------------------------------
for _, name in ipairs({ "love.system", "love.timer", "love.thread", "love.filesystem",
                        "love.audio", "love.sound", "love.graphics", "love.event",
                        "love.data", "love.window", "love.mouse", "love.joystick",
                        "love.keyboard", "love.touch" }) do
  package.preload[name] = function() return true end
end

function love._missing_report()
  local out = {}
  for k, v in pairs(missing) do out[#out + 1] = k .. " x" .. v end
  table.sort(out)
  return out
end
