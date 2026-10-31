-- play.lua
-- Runs the real Balatro Lua code on the Wii and draws it with the C renderer (gfx).
-- Controls: Wiimote pointer = mouse, A = left click, B = right click,
--           PLUS = options, MINUS = run info, HOME = exit.

local ROOT = rawget(_G, "BALATRO_ROOT") or "sd:/balatro"
local SRC  = ROOT .. "/src/"
local log  = wii.log

-- tuning knobs
local GC_PAUSE = 140      -- lower = Lua keeps less garbage around (less memory, a bit more GC work)
local GC_STEPMUL = 400  -- bigger = the collector keeps up better, so no long stop is needed
local GC_HARD_KB = 28000
local LOW_MEM_KB = 5000   -- free memory (not taken + holes in the heap) below this triggers a clean-up  -- if Lua memory goes above this, run a full collection (at most once a second)
local REDUCED_MOTION = true  -- no card shaking / tilting (big saving); the option in the menu is forced on at start
local HIDE_BG_IN_MENUS = true -- do not draw the game behind menus (View Deck etc. get much lighter)
local NATIVE_NAV = true   -- d-pad / stick move between buttons like a PS4 pad (false = moves a cursor)
local CURSOR_SPEED = 380  -- pixels per second for the stick / d-pad cursor
local ADAPTIVE_VSYNC = true -- a slow frame does not wait for the next screen refresh (saves a few ms per frame)
local GC_AB_TEST = false    -- measurement only (it nearly ran the Wii out of memory): garbage collector off / on every 15 s
local USE_PICTURE_CACHE = false -- measured: reading the cache is not faster than decoding the PNG files
local SHADOWS_OFF = true  -- card shadows are a second draw pass: turning them off makes drawing cheaper
local PROFILE  = true     -- sample where the Lua time goes and write the top spots to the report

package.path = SRC .. "?.lua"
package.cpath = ""
arg = {}
bit = require("bit")

-- keep the report quiet: only the first few print() calls are logged
local printed = 0
print = function(...)
  printed = printed + 1
  if printed <= 12 then
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
    log("print: " .. table.concat(t, " "))
  end
end

-- Random numbers. Balatro runs on LuaJIT, and a seed only deals the same cards when the random
-- generator is the same one. The new boot.dol has LuaJIT's generator in C (gfx.rng_seed / gfx.rng).
-- Without it (old boot.dol) the older fix is used: Lua 5.1 math.randomseed() cuts the number to a
-- whole integer, so every seed between 0 and 1 became 0; fold the fraction in.
RNG_LUAJIT = false
do
  local g = rawget(_G, "gfx")
  if g and g.rng_seed and g.rng then
    local rng, rng_seed, floor = g.rng, g.rng_seed, math.floor
    math.randomseed = function(x) rng_seed(tonumber(x) or 0) end
    math.random = function(m, n)
      local d = rng()
      if m == nil then return d end
      m = tonumber(m)
      if n == nil then
        if not (m >= 1) then error("bad argument #1 to 'random' (interval is empty)", 2) end
        return floor(d * m) + 1
      end
      n = tonumber(n)
      if not (m <= n) then error("bad argument #2 to 'random' (interval is empty)", 2) end
      return floor(d * (n - m + 1)) + m
    end
    RNG_LUAJIT = true
    log("random numbers: LuaJIT compatible generator is on")
  else
    local orig_seed = math.randomseed
    math.randomseed = function(x)
      x = tonumber(x) or 0
      local ip = math.floor(x)
      local fp = x - ip
      local v = (ip % 2147483647) + math.floor(fp * 2147483647)
      orig_seed(v % 2147483647)
    end
    log("random numbers: OLD generator (seeds will NOT match the PC game). Rebuild boot.dol with make.")
  end
end

local function show_error_screen(err)
  local lines = {}
  for line in (tostring(err) .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("sd:/balatro/src/", ""):gsub("\t", "  ")
    lines[#lines + 1] = line:sub(1, 70)
    if #lines >= 22 then break end
  end
  local ok, fid = pcall(function() return (gfx.new_font(SRC .. "resources/fonts/m6x11plus.ttf", 16, 16)) end)
  if not ok then fid = nil end
  while true do
    gfx.begin_frame()
    gfx.clear(0.45, 0, 0)
    if fid then
      gfx.set_color(1, 1, 1, 1)
      for i, line in ipairs(lines) do gfx.draw_text(fid, line, 12, 8 + (i - 1) * 18, 0, 1, 1, 0, 0) end
      gfx.draw_text(fid, "Press HOME to exit", 12, 450, 0, 1, 1, 0, 0)
    end
    gfx.end_frame()
    if bit.band(wii.pad(), 64) ~= 0 then return end
  end
end

local function traceback_handler(e) return debug.traceback(tostring(e), 2) end

local function log_error(err)
  log("")
  log("ERROR:")
  local n = 0
  for line in (tostring(err) .. "\n"):gmatch("(.-)\n") do
    n = n + 1
    if n <= 22 then log(line) end
  end
  local missing = (love and love._missing_report) and love._missing_report() or {}
  log("unknown love API calls: " .. #missing)
  for i = 1, math.min(#missing, 40) do log("  " .. missing[i]) end
end

-- show that the program started (dark green), then load the game
-- a loading screen (text and a bar), drawn between the picture loads
local loading = { fid = nil, n = 0, last = -1 }
local LOADING_TOTAL = 66
local function loading_frame()
  local now = wii.time()
  local dots = string.rep(".", math.floor(now * 2) % 4)
  gfx.begin_frame()
  gfx.clear(0.08, 0.2, 0.18)
  gfx.origin()
  gfx.set_corner_colors()
  if loading.fid then
    gfx.set_color(1, 1, 1, 1)
    gfx.draw_text(loading.fid, "Loading" .. dots, 50, 372, 0, 2, 2, 0, 0)
    gfx.set_color(0.8, 0.95, 0.9, 1)
    gfx.draw_text(loading.fid, "Shuffling the deck...", 50, 420, 0, 1, 1, 0, 0)
  end
  local w = 440 * math.min(1, loading.n / LOADING_TOTAL)
  gfx.set_color(0, 0, 0, 0.4); gfx.rect(true, 50, 452, 440, 8)
  gfx.set_color(0.95, 0.75, 0.2, 1); gfx.rect(true, 50, 452, w, 8)
  gfx.end_frame()
end

local function splash_frame()
  gfx.begin_frame()
  gfx.clear(0.08, 0.2, 0.18)
  gfx.end_frame()
end

local function mem_line()
  local imgs, texkb, fonts = gfx.stats()
  local used, total, free = wii.heap()
  local a1, a2 = wii.arena()
  return string.format("lua %d KB | textures %d KB (%d images, %d fonts) | malloc used %d total %d free %d KB | arena1 %d KB arena2 %d KB",
    math.floor(collectgarbage("count")), texkb, imgs, fonts,
    math.floor(used / 1024), math.floor(total / 1024), math.floor(free / 1024), a1, a2)
end

local function state_name()
  if G and G.STATES then
    for k, v in pairs(G.STATES) do
      if v == G.STATE then return k end
    end
  end
  return tostring(G and G.STATE)
end

local quit_requested = false
local REQUIRED_GFX_VERSION = 5

local function load_game()
  if (gfx.version or 0) < REQUIRED_GFX_VERSION then
    error("boot.dol is OLDER than the Lua scripts. Rebuild with make, then copy balatro-wii.dol to apps/balatro-wii/boot.dol")
  end
  wii.mkdir(ROOT .. "/save")
  SAFE_MODE = wii.stat(ROOT .. "/safe.txt") ~= nil     -- an empty file safe.txt turns all the tweaks off
  BENCH_MODE = wii.stat(ROOT .. "/bench.txt") ~= nil   -- an empty file bench.txt starts the same test run every time
  if SAFE_MODE then log("SAFE MODE: opt.lua and srcpatch.lua are not loaded") end
  if BENCH_MODE then log("BENCH MODE: a fixed test run starts by itself") end
  if USE_PICTURE_CACHE then gfx.set_cache_dir(ROOT .. "/cache") end
  dofile(ROOT .. "/wii/love_stub.lua")
  if not SAFE_MODE then
    local ok_sp, err_sp = pcall(dofile, ROOT .. "/wii/srcpatch.lua")
    if not ok_sp then log("srcpatch.lua failed: " .. tostring(err_sp)) end
  end
  local t0 = wii.time()
  dofile(SRC .. "main.lua")
  log(string.format("main.lua loaded in %.2f s", wii.time() - t0))
  log("  " .. mem_line())

  -- the splash intro needs shaders and spawns 200 cards: go straight to the main menu
  local original_splash = Game.splash_screen
  Game.splash_screen = function(self)
    G.SETTINGS.skip_splash = "Yes"
    return original_splash(self)
  end
  splash_frame()
  -- loading screen: a frame about every 0.25 s while the pictures are loaded (also counts what takes the time)
  local ok_f, f_id = pcall(function() return (gfx.new_font(SRC .. "resources/fonts/m6x11plus.ttf", 16, 16)) end)
  loading.fid = ok_f and f_id or nil
  local real_load_image = gfx.load_image
  local img_time, img_count = 0, 0
  gfx.load_image = function(...)
    local ta = wii.time()
    local a, b, c = real_load_image(...)
    img_time = img_time + (wii.time() - ta)
    img_count = img_count + 1
    loading.n = img_count
    if wii.time() - loading.last > 0.25 then
      loading.last = wii.time()
      loading_frame()
    end
    return a, b, c
  end
  t0 = wii.time()
  love.load(love.arg.parseGameArguments(arg), arg)
  gfx.load_image = real_load_image
  log(string.format("  pictures: %d loaded in %.2f s (the rest of love.load: %.2f s)", img_count, img_time, wii.time() - t0 - img_time))
  log(string.format("love.load took %.2f s", wii.time() - t0))
  do
    local hits, misses, writes = gfx.cache_info()
    log(string.format("  picture cache: %d read from the cache, %d decoded from PNG, %d cache files written", hits, misses, writes))
  end
  log("  " .. mem_line())

  -- a fresh profile starts the scripted tutorial (fixed seed, red deck): skip it
  if G.SETTINGS then G.SETTINGS.tutorial_complete = true end

  -- the game stops Lua's garbage collector and only steps it for 0.3 ms a frame (made for a PC
  -- with lots of RAM). On the Wii the memory just grew until it ran out: use the normal collector.
  nuGC = function() end
  collectgarbage("restart")
  collectgarbage("setpause", GC_PAUSE)
  collectgarbage("setstepmul", GC_STEPMUL)

  -- the language screen crashes and we only need English: make its buttons do nothing
  local lang_names = {}
  for k, _ in pairs(G.FUNCS) do
    if type(k) == "string" and k:lower():find("lang") then lang_names[#lang_names + 1] = k end
  end
  for _, k in ipairs(lang_names) do G.FUNCS[k] = function() end end
  log("language functions disabled: " .. table.concat(lang_names, ", "))

  if REDUCED_MOTION then G.SETTINGS.reduced_motion = true end
  if HIDE_BG_IN_MENUS then G.F_HIDE_BG = true end
  if not SAFE_MODE then
    local ok_opt, err_opt = pcall(dofile, ROOT .. "/wii/opt.lua")
    if not ok_opt then log("opt.lua failed: " .. tostring(err_opt)) end
  end
  -- diagnostics: write the first hover changes to the report (to find out why a tooltip may flicker)
  do
    local hover_logs = 0
    local function hname(x)
      if not x then return "nil" end
      if x == G.ROOM then return "ROOM" end
      if Tag and getmetatable(x) == Tag then return "Tag" end
      local id = x.config and (x.config.id or x.config.button) or nil
      local c = (UIElement and getmetatable(x) == UIElement and "UIE") or (Card and getmetatable(x) == Card and "Card")
                or (UIBox and getmetatable(x) == UIBox and "UIBox") or "?"
      return c .. (id and (":" .. tostring(id)) or "")
    end
    local orig_set_hover = Controller.set_cursor_hover
    Controller.set_cursor_hover = function(self)
      local before = self.cursor_hover.target
      local r = orig_set_hover(self)
      local after = self.cursor_hover.target
      if after ~= before and hover_logs < 120 then
        hover_logs = hover_logs + 1
        log(string.format("hover %s -> %s | locked=%s interrupt=%s coyote=%s lockframe=%s hid=%s",
          hname(before), hname(after), tostring(self.locked), tostring(self.interrupt and self.interrupt.focus),
          tostring(self.COYOTE_FOCUS), tostring(self.locks and self.locks.frame),
          self.HID and (self.HID.controller and "pad" or "mouse") or "?"))
      end
      return r
    end
  end
  -- the Quit button on the main menu: leave to the Wii Menu (HOME still goes back to the Homebrew Channel)
  G.FUNCS.quit = function() quit_requested = true end
  if SHADOWS_OFF and G.SETTINGS.GRAPHICS then G.SETTINGS.GRAPHICS.shadows = "Off" end

  -- High Contrast Cards: the port normally uses the normal card picture for both settings (saves memory and
  -- loading time). When the option is switched on, load the real high contrast pictures first.
  if G.FUNCS and G.FUNCS.refresh_contrast_mode and G.asset_atli then
    local orig_contrast = G.FUNCS.refresh_contrast_mode
    G.FUNCS.refresh_contrast_mode = function(...)
      if G.SETTINGS.colourblind_option then
        WII_REAL_OPT2 = true
        for _, a in ipairs(G.asset_atli) do
          if a.name == "cards_2" or a.name == "ui_2" then
            local atlas = G.ASSET_ATLAS[a.name]
            if atlas and not atlas.wii_real then
              local ok, img = pcall(love.graphics.newImage, a.path,
                { mipmaps = true, dpiscale = G.SETTINGS.GRAPHICS.texture_scaling })
              if ok and img then
                atlas.image = img
                atlas.wii_real = true
                log("high contrast picture loaded: " .. a.name)
              else
                log("high contrast picture FAILED: " .. a.name)
              end
            end
          end
        end
        WII_REAL_OPT2 = nil
      end
      return orig_contrast(...)
    end
  end

  -- note every key typed into a text field (the seed box): shows if a key like "2" gets lost on the way
  if G.FUNCS and G.FUNCS.text_input_key then
    local orig_key = G.FUNCS.text_input_key
    local typed = 0
    G.FUNCS.text_input_key = function(args)
      typed = typed + 1
      if typed <= 200 then
        local sh = G.CONTROLLER and G.CONTROLLER.text_input_hook
        local ok, cur = pcall(function() return sh.config.ref_table.text.ref_table[sh.config.ref_table.text.ref_value] end)
        log("text key: " .. tostring(args and args.key) .. "  (text before: " .. tostring(ok and cur or "?") .. ")")
      end
      return orig_key(args)
    end
  end

  -- note the seed of every run in the report (to find out why the cards look the same)
  local original_start_run = Game.start_run
  Game.start_run = function(self, args)
    -- the tutorial profile data forces the same voucher and skip tags: remove them
    G.SETTINGS.tutorial_complete = true
    local tp = G.SETTINGS.tutorial_progress
    if type(tp) == "table" then tp.forced_voucher = nil; tp.forced_tags = nil end
    local r = original_start_run(self, args)
    local seed = G.GAME and G.GAME.pseudorandom and G.GAME.pseudorandom.seed
    log("start_run: seed=" .. tostring(seed) .. " seeded=" .. tostring(G.GAME and G.GAME.seeded) ..
        " tutorial_complete=" .. tostring(G.SETTINGS.tutorial_complete) ..
        " args.seed=" .. tostring(args and args.seed) ..
        " reduced_motion=" .. tostring(G.SETTINGS.reduced_motion))
    return r
  end

  -- the Wii cannot run GLSL: give every shader the game knows a dummy object
  G.SHADERS = G.SHADERS or {}
  for _, name in ipairs({ "background", "booster", "CRT", "debuff", "dissolve", "flame",
                          "flash", "foil", "gold_seal", "holo", "hologram", "negative",
                          "negative_shine", "played", "polychrome", "skew", "splash",
                          "vortex", "voucher" }) do
    if not G.SHADERS[name] then
      G.SHADERS[name] = love.graphics.newShader("resources/shaders/" .. name .. ".fs")
    end
  end
end

-- ---------------------------------------------------------------------------
-- sampling profiler: every 1000 Lua instructions note which function is running,
-- and which kind of object / which UI box it belongs to
local prof = {}
local prof_cls = {}
local prof_own = {}
local prof_total = 0
local prof_alloc = {}
local prof_last_mem = 0
local class_of = nil
local OWNERS = { "HUD", "buttons", "blind_select", "shop", "HUD_blind", "HUD_tags", "blind_prompt_box" }

local function build_classes()
  class_of = {}
  for _, n in ipairs({ "UIElement", "UIBox", "DynaText", "Card", "CardArea", "Sprite", "AnimatedSprite",
                       "Particles", "Moveable", "Node", "Blind" }) do
    local c = rawget(_G, n)
    if c then class_of[c] = n end
  end
end

local function owner_name(box)
  if not box then return "none" end
  for i = 1, #OWNERS do
    if G[OWNERS[i]] == box then return OWNERS[i] end
  end
  if box == G.OVERLAY_MENU then return "overlay" end
  return "other"
end

local function prof_hook()
  local info = debug.getinfo(2, "S")
  local key
  if info.what == "C" then key = "[C function]"
  else key = (info.short_src or "?"):gsub("^sd:/balatro/src/", "") .. ":" .. tostring(info.linedefined) end
  prof[key] = (prof[key] or 0) + 1
  prof_total = prof_total + 1
  local mem = collectgarbage("count")
  local grown = mem - prof_last_mem
  prof_last_mem = mem
  if grown > 0 then prof_alloc[key] = (prof_alloc[key] or 0) + grown end

  local nm, obj = debug.getlocal(2, 1)
  if nm == "self" and type(obj) == "table" then
    if not class_of then build_classes() end
    local c = class_of[getmetatable(obj)]
    if c then
      prof_cls[c] = (prof_cls[c] or 0) + 1
      if c == "UIElement" or c == "UIBox" then
        local k = owner_name(c == "UIBox" and obj or obj.UIBox) .. "/" .. c
        prof_own[k] = (prof_own[k] or 0) + 1
      end
    end
  end
end

local function top_list(t, n, total, label)
  local arr = {}
  for k, v in pairs(t) do arr[#arr + 1] = { k, v } end
  table.sort(arr, function(a, b) return a[2] > b[2] end)
  local parts = {}
  for i = 1, math.min(n, #arr) do
    parts[#parts + 1] = string.format("%s %.0f%%", arr[i][1], arr[i][2] * 100 / total)
  end
  log("    " .. label .. ": " .. table.concat(parts, ", "))
end

local function count_objects()
  if not class_of then build_classes() end
  local counts, owners = {}, {}
  for _, v in pairs(G.MOVEABLES or {}) do
    local c = class_of[getmetatable(v)] or "?"
    counts[c] = (counts[c] or 0) + 1
    if c == "UIElement" then
      local o = owner_name(v.UIBox)
      owners[o] = (owners[o] or 0) + 1
    end
  end
  local n = 0
  for _, v in pairs(counts) do n = n + v end
  top_list(counts, 8, math.max(n, 1), "objects (" .. n .. ")")
  top_list(owners, 8, math.max(n, 1), "UI elements by box (share of all objects)")
end

local function prof_report()
  if prof_total == 0 then return end
  local arr = {}
  for k, v in pairs(prof) do arr[#arr + 1] = { k, v } end
  table.sort(arr, function(a, b) return a[2] > b[2] end)
  log("    profile (" .. prof_total .. " samples):")
  for i = 1, math.min(14, #arr) do
    log(string.format("      %4.1f%%  %s", arr[i][2] * 100 / prof_total, arr[i][1]))
  end
  do
    local tot = 0
    for _, v in pairs(prof_alloc) do tot = tot + v end
    if tot > 0 then top_list(prof_alloc, 8, tot, "memory churn by function (" .. math.floor(tot) .. " KB)") end
  end
  top_list(prof_cls, 8, prof_total, "time by object type")
  top_list(prof_own, 10, prof_total, "time by UI box")
  pcall(count_objects)
  prof, prof_cls, prof_own, prof_total, prof_alloc = {}, {}, {}, 0, {}
end

local held_prev = 0
local last_mx, last_my = nil, nil
local last_pump = nil
local ptr_x, ptr_y, ptr_t = 0, 0, -100   -- last pointer position and when it was seen

-- Native game-controller mode: the d-pad / stick move the game's own focus frame from
-- element to element (like a PS4 / Switch pad). The game thinks a normal gamepad is plugged in.
local pad_axes = { leftx = 0, lefty = 0, rightx = 0, righty = 0, triggerleft = 0, triggerright = 0 }
local FAKE_PAD = {
  getGamepadMappingString = function() return "00000000000000000000000000000000,Nintendo Wii,a:b0,b:b1,x:b2,y:b3," end,
  getGamepadAxis = function(_, name) return pad_axes[name] or 0 end,
  isGamepad = function() return true end,
  isGamepadDown = function() return false end,
  setVibration = function() end,
}
local gp_mode = false
local gp_ref_x, gp_ref_y = 0, 0
local gp_down = {}
-- game button name, mask of the merged input bits that count as pressed
-- sideways Wiimote: A = game "x" (Play Hand), B = game "y" (Discard). In the shop the game puts
-- Next Round on "y" and Reroll on "x", so there the two are swapped: A = Next Round, B = Reroll.
local MASK_PAD_A, MASK_PAD_B = 2048 + 262144, 4096 + 131072
local shop_swap = false
local kb_mode, kb_log = false, 0
local GP_BUTTONS = {
  { "a", 32768 }, { "b", 65536 }, { "x", MASK_PAD_A }, { "y", MASK_PAD_B },
  { "leftshoulder", 8192 }, { "rightshoulder", 16384 },
  { "dpup", 128 }, { "dpdown", 256 }, { "dpleft", 512 }, { "dpright", 1024 },
}
local function registry_has(button)
  local C = G and G.CONTROLLER
  local r = C and C.button_registry and C.button_registry[button]
  return r and r[1] and not r[1].node.under_overlay
end
local pm_state = { plus = { down = false }, minus = { down = false } }
local PM_BUTTONS = {
  { slot = "plus", mask = 16, shoulder = "rightshoulder", main = "start", action = function()
      if G.OVERLAY_MENU then G.FUNCS.exit_overlay_menu() else G.FUNCS.options({ config = {} }) end
    end },
  { slot = "minus", mask = 32, shoulder = "leftshoulder", main = "back", action = function()
      if G.OVERLAY_MENU then G.FUNCS.exit_overlay_menu()
      elseif G.STAGE == G.STAGES.RUN then G.FUNCS.run_info({ config = {} }) end
    end },
}
local GP_ENTER_MASK = 128 + 256 + 512 + 1024 + 2048 + 4096 + 8192 + 16384

local function gp_release_all()
  for name, down in pairs(gp_down) do
    if down then love.gamepadreleased(FAKE_PAD, name) end
  end
  gp_down = {}
  pad_axes.leftx, pad_axes.lefty = 0, 0
end

local function pump_input()
  local held, stick_x, stick_y = wii.pad()
  stick_x, stick_y = stick_x or 0, stick_y or 0
  local pressed = bit.band(held, bit.bnot(held_prev))
  local released = bit.band(held_prev, bit.bnot(held))
  held_prev = held
  local now = wii.time()
  local fdt = math.min(now - (last_pump or now), 0.1)
  last_pump = now

  local x, y = wii.ir()

  if NATIVE_NAV then
    -- d-pad, stick, X/Y/L/R switch to controller mode; moving the pointer far switches back
    if not gp_mode then
      if bit.band(pressed, GP_ENTER_MASK) ~= 0 or (stick_x * stick_x + stick_y * stick_y) > 0.36 then
        gp_mode = true
        gp_ref_x, gp_ref_y = x or ptr_x, y or ptr_y
      end
    elseif x and (math.abs(x - gp_ref_x) + math.abs(y - gp_ref_y)) > 40 then
      gp_mode = false
      gp_release_all()
    end
  end

  if x and not (NATIVE_NAV and gp_mode) then
    ptr_x, ptr_y, ptr_t = x, y, now
    local dx, dy = 0, 0
    if last_mx then dx, dy = x - last_mx, y - last_my end
    if dx ~= 0 or dy ~= 0 or not last_mx then
      love._set_mouse(x, y)
      love.mousemoved(x, y, dx, dy, false)
    end
    last_mx, last_my = x, y
  end

  if NATIVE_NAV and gp_mode then
    -- stick: the game reads the axes itself
    pad_axes.leftx, pad_axes.lefty = stick_x, stick_y
    if math.abs(stick_x) > 0.2 then love.joystickaxis(FAKE_PAD, "leftx", stick_x) end
    if math.abs(stick_y) > 0.2 then love.joystickaxis(FAKE_PAD, "lefty", stick_y) end
    -- the choice is made only while neither A nor B is held (no half-pressed switch)
    if bit.band(held, MASK_PAD_A + MASK_PAD_B) == 0 then
      shop_swap = (G and G.STATES and G.STATE == G.STATES.SHOP) and true or false
    end
    -- while the on-screen keyboard is open (seed box): 1 = Backspace, 2 = press a letter (unchanged),
    -- A = Enter, B = Back. Backspace / Enter / Back are sent straight to the text field (the keyboard's own
    -- Enter and Back keys do the same thing: key "return"). kb_mode is updated AFTER the loop and only while
    -- none of the four buttons is held, so a release always matches its press.
    for i = 1, #GP_BUTTONS do
      local name, mask = GP_BUTTONS[i][1], GP_BUTTONS[i][2]
      if kb_mode and (name == "b" or name == "x" or name == "y") then
        local down = bit.band(held, mask) ~= 0
        local slot = "kb_" .. name
        if down and not gp_down[slot] then
          local key = (name == "b") and "backspace" or "return"
          if kb_log < 40 then
            kb_log = kb_log + 1
            log("keyboard pad: " .. name .. " (mask " .. mask .. ") -> " .. key)
          end
          local ok, err = pcall(function() G.FUNCS.text_input_key({ key = key }) end)
          if not ok then log("keyboard pad failed: " .. tostring(err)) end
        end
        gp_down[slot] = down
      else
        if shop_swap then
          if name == "x" then mask = MASK_PAD_B elseif name == "y" then mask = MASK_PAD_A end
        end
        local down = bit.band(held, mask) ~= 0
        if down and not gp_down[name] then
          love.gamepadpressed(FAKE_PAD, name)
        elseif gp_down[name] and not down then
          love.gamepadreleased(FAKE_PAD, name)
        end
        gp_down[name] = down
      end
    end
    if bit.band(held, 32768 + 65536 + MASK_PAD_A + MASK_PAD_B) == 0 then
      local C = G and G.CONTROLLER
      kb_mode = (C and C.text_input_hook) and true or false
    end
    -- PLUS and MINUS (a sideways Wiimote has no shoulder buttons): when the game shows an R / L
    -- prompt (Buy, Sell...) they press that, otherwise they do Options / Run Info
    for i = 1, #PM_BUTTONS do
      local pm = PM_BUTTONS[i]
      local down = bit.band(held, pm.mask) ~= 0
      local st = pm_state[pm.slot]
      if down and not st.down then
        if registry_has(pm.shoulder) then
          st.target = pm.shoulder
        elseif registry_has(pm.main) then
          st.target = pm.main
        else
          st.target = "action"
          local ok, err = pcall(pm.action)
          if not ok then log(pm.slot .. " failed: " .. tostring(err)) end
        end
        if st.target ~= "action" then love.gamepadpressed(FAKE_PAD, st.target) end
      elseif st.down and not down then
        if st.target and st.target ~= "action" then love.gamepadreleased(FAKE_PAD, st.target) end
        st.target = nil
      end
      st.down = down
    end
  else
    -- mouse mode (pointer): A = left click, B = right click, PLUS = options, MINUS = run info
    if not NATIVE_NAV then
      -- no native navigation: stick / d-pad move a cursor instead
      if bit.band(held, 128) ~= 0 then stick_y = -1 end
      if bit.band(held, 256) ~= 0 then stick_y = 1 end
      if bit.band(held, 512) ~= 0 then stick_x = -1 end
      if bit.band(held, 1024) ~= 0 then stick_x = 1 end
      if stick_x ~= 0 or stick_y ~= 0 then
        local cx, cy = love.mouse.getPosition()
        local nx = math.max(0, math.min(639, cx + stick_x * CURSOR_SPEED * fdt))
        local ny = math.max(0, math.min(479, cy + stick_y * CURSOR_SPEED * fdt))
        love._set_mouse(nx, ny)
        love.mousemoved(nx, ny, nx - cx, ny - cy, false)
        ptr_x, ptr_y, ptr_t = nx, ny, now
        last_mx, last_my = nx, ny
      end
    end

    local mx, my = love.mouse.getPosition()
    if bit.band(pressed, 1) ~= 0 then love.mousepressed(mx, my, 1, false) end
    if bit.band(released, 1) ~= 0 then love.mousereleased(mx, my, 1) end
    if bit.band(pressed, 2) ~= 0 then love.mousepressed(mx, my, 2, false) end
    if bit.band(released, 2) ~= 0 then love.mousereleased(mx, my, 2) end

    if bit.band(pressed, 16) ~= 0 then
      local ok, err = pcall(function()
        if G.OVERLAY_MENU then G.FUNCS.exit_overlay_menu() else G.FUNCS.options({ config = {} }) end
      end)
      if not ok then log("options failed: " .. tostring(err)) end
    end
    if bit.band(pressed, 32) ~= 0 then
      local ok, err = pcall(function()
        if G.OVERLAY_MENU then G.FUNCS.exit_overlay_menu()
        elseif G.STAGE == G.STAGES.RUN then G.FUNCS.run_info({ config = {} }) end
      end)
      if not ok then log("run info failed: " .. tostring(err)) end
    end
  end
  return bit.band(held, 64) ~= 0     -- HOME
end

-- ---------------------------------------------------------------------------
local dt_smooth = 1 / 100
local n_frames, n_logic, n_gpu, n_draws = 0, 0, 0, 0
local n_upd, n_drw = 0, 0
local report_t = nil

-- how long the C drawing functions take (only every 8th frame is measured, the timer itself costs a little)
local gfx_orig, gfx_wrapped, gfx_times, gfx_calls = {}, {}, {}, {}
local gfx_timer_cost = 0
local gfx_sampled = 0
local function setup_gfx_timing()
  local skip = { begin_frame = true, end_frame = true, load_image = true, new_font = true, set_cache_dir = true,
                 cache_info = true, set_adaptive_vsync = true, stats = true }
  for k, v in pairs(gfx) do
    if type(v) == "function" and not skip[k] then
      gfx_orig[k] = v
      gfx_wrapped[k] = function(...)
        local t = wii.time()
        local a, b, c, d = v(...)
        gfx_times[k] = (gfx_times[k] or 0) + (wii.time() - t)
        gfx_calls[k] = (gfx_calls[k] or 0) + 1
        return a, b, c, d
      end
    end
  end
  local t = wii.time()
  for _ = 1, 500 do local a = wii.time() end
  gfx_timer_cost = (wii.time() - t) / 500        -- cost of one wii.time() call, in seconds
end
local function gfx_timing_on()
  for k, w in pairs(gfx_wrapped) do gfx[k] = w end
end
local function gfx_timing_off()
  for k, v in pairs(gfx_orig) do gfx[k] = v end
end
local function gfx_timing_report()
  if gfx_sampled == 0 then return end
  local total, calls = 0, 0
  local arr = {}
  for k, v in pairs(gfx_times) do
    total = total + v
    calls = calls + (gfx_calls[k] or 0)
    arr[#arr + 1] = { k, v, gfx_calls[k] or 0 }
  end
  table.sort(arr, function(a, b) return a[2] > b[2] end)
  local net = math.max(0, total - calls * gfx_timer_cost * 2)
  local parts = {}
  for i = 1, math.min(4, #arr) do
    parts[#parts + 1] = string.format("%s %.1f ms (%d calls)", arr[i][1], arr[i][2] / gfx_sampled * 1000, arr[i][3] / gfx_sampled)
  end
  log(string.format("    C drawing (per frame, timer cost removed): %.1f ms in %d calls | %s",
    net / gfx_sampled * 1000, calls / gfx_sampled, table.concat(parts, ", ")))
  gfx_times, gfx_calls, gfx_sampled = {}, {}, 0
end

local function run_frames()
  setup_gfx_timing()
  gfx.set_adaptive_vsync(ADAPTIVE_VSYNC)
  local frame_no = 0
  local was_wiping, wipe_logs, last_wipe_log = false, 0, -10
  -- garbage collector on/off measurement
  local ab = { on = true, t = wii.time(), frames = 0, upd = 0, drw = 0, states = {} }
  -- fixed test run
  local bench = { t = wii.time(), started = false, selected = false }
  report_t = wii.time()
  local last_full = -10
  local last_arena = 0
  local gc_backoff = 3
  if PROFILE then debug.sethook(prof_hook, "", 1000) end
  while true do
    local t0 = wii.time()
    -- a profile switch loads its own setting; the screen wipe (after Play) needs real time for its colours
    if REDUCED_MOTION then G.SETTINGS.reduced_motion = not G.screenwipe end
    if quit_requested then wii.menu(); return end
    if pump_input() then return end
    local dt = love.timer.step()
    dt_smooth = math.min(0.8 * dt_smooth + 0.2 * dt, 0.1)
    frame_no = frame_no + 1
    -- the loading transition (after Play) must look like the original game
    local wiping = G.screenwipe and true or false
    if wiping ~= was_wiping then
      was_wiping = wiping
      if WII_OPT_WIPE then WII_OPT_WIPE(wiping) end
      if HIDE_BG_IN_MENUS then G.F_HIDE_BG = not wiping end
      log("screen wipe " .. (wiping and "starts" or "ends"))
    end
    if wiping and wipe_logs < 30 and wii.time() - last_wipe_log > 0.35 then
      wipe_logs = wipe_logs + 1
      last_wipe_log = wii.time()
      local w = G.screenwipe
      local kids = 0
      for _ in pairs(w.UIRoot and w.UIRoot.children or {}) do kids = kids + 1 end
      log(string.format("wipe: T(%.1f,%.1f %.1fx%.1f s%.2f) VT(%.1f,%.1f %.1fx%.1f s%.2f) visible=%s children=%d",
        w.T.x, w.T.y, w.T.w, w.T.h, w.T.scale or 0, w.VT.x, w.VT.y, w.VT.w, w.VT.h, w.VT.scale or 0,
        tostring(w.states and w.states.visible), kids))
    end
    local tu = wii.time()
    love.update(dt_smooth)
    local tu2 = wii.time()
    gfx.begin_frame()
    local sampling = (frame_no % 8 == 0)
    if sampling then gfx_timing_on() end
    love.draw()
    if sampling then gfx_timing_off(); gfx_sampled = gfx_sampled + 1 end
    local tu3 = wii.time()
    n_upd = n_upd + (tu2 - tu)
    n_drw = n_drw + (tu3 - tu2)

    -- garbage collector on/off windows of 15 s, only while a run is on screen
    if GC_AB_TEST and G.STAGE == G.STAGES.RUN then
      ab.frames = ab.frames + 1
      ab.upd = ab.upd + (tu2 - tu)
      ab.drw = ab.drw + (tu3 - tu2)
      local sn = state_name()
      ab.states[sn] = (ab.states[sn] or 0) + 1
      if wii.time() - ab.t >= 15 then
        local best, bestn = "?", 0
        for k, v in pairs(ab.states) do if v > bestn then best, bestn = k, v end end
        if ab.frames > 20 then
          log(string.format("GC TEST: garbage collector %s: %d frames, update %.1f ms, draw %.1f ms (mostly %s)",
            ab.on and "ON " or "OFF", ab.frames, ab.upd / ab.frames * 1000, ab.drw / ab.frames * 1000, best))
        end
        ab.frames, ab.upd, ab.drw, ab.states, ab.t = 0, 0, 0, {}, wii.time()
        if ab.on then
          local _, a2 = wii.arena()
          local _, _, hf = wii.heap()
          if a2 + (hf or 0) / 1024 > 14000 then collectgarbage("stop"); ab.on = false end
        else
          collectgarbage("collect")
          collectgarbage("restart")
          collectgarbage("setpause", GC_PAUSE)
          collectgarbage("setstepmul", GC_STEPMUL)
          ab.on = true
        end
      end
    end

    -- fixed test run (bench.txt): same seed, same scene, no input needed
    if BENCH_MODE then
      if not bench.started and G.STAGE == G.STAGES.MAIN_MENU and not G.screenwipe and wii.time() - bench.t > 4 then
        bench.started = true
        bench.t = wii.time()
        local ok, err = pcall(function() G.FUNCS.start_run(nil, { stake = 1, seed = "BENCHMRK" }) end)
        log("bench: run started " .. (ok and "ok" or tostring(err)))
      elseif bench.started and not bench.selected and G.STATE == G.STATES.BLIND_SELECT and wii.time() - bench.t > 3
             and G.blind_select_opts and G.blind_select_opts.small then
        -- wait until the blind choice screen really exists (it is built a moment after the state changes)
        local btn = G.blind_select_opts.small:get_UIE_by_ID("select_blind_button")
        if btn then
          bench.selected = true
          local ok, err = pcall(function() G.FUNCS.select_blind(btn) end)
          log("bench: small blind selected " .. (ok and "ok" or tostring(err)))
        end
      end
    end
    gfx.origin()
    gfx.set_corner_colors()
    if wii.time() - ptr_t < 3 then gfx.draw_cursor(ptr_x, ptr_y, 1.0) end
    local t1 = wii.time()
    love.thread._run_all()
    local gpu = gfx.end_frame()

    -- low on real memory: clean up now (Lua garbage first, then the sound cache)
    if wii.time() - last_arena > 1 then
      last_arena = wii.time()
      local _, a2 = wii.arena()
      local _, _, hf = wii.heap()
      local free_kb = a2      -- memory not yet taken (the holes inside the heap are not reliable for big allocations)
      if free_kb < LOW_MEM_KB and wii.time() - last_full > gc_backoff then
        local tg = wii.time()
        local before = collectgarbage("count")
        collectgarbage("collect")
        last_full = wii.time()
        local _, a3 = wii.arena()
        local _, _, hf3 = wii.heap()
        local gain = a3 - free_kb
        gc_backoff = (gain < 1500) and math.min(gc_backoff * 2, 60) or 3   -- do not repeat a clean-up that does not help
        log(string.format("low memory (%d KB free): gc %d KB -> %d KB in %.0f ms (gained %d KB)", free_kb, before, collectgarbage("count"), (last_full - tg) * 1000, gain))
        if free_kb < LOW_MEM_KB / 2 and rawget(_G, "snd") then snd.trim() end
      end
    end
    if collectgarbage("count") > GC_HARD_KB and wii.time() - last_full > 1 then
      local tg = wii.time()
      local before = collectgarbage("count")
      collectgarbage("collect")
      last_full = wii.time()
      log(string.format("full gc: %d KB -> %d KB in %.0f ms", before, collectgarbage("count"), (last_full - tg) * 1000))
    end

    n_frames = n_frames + 1
    n_logic = n_logic + (t1 - t0)
    n_gpu = n_gpu + gpu
    local d = love._counts()
    n_draws = n_draws + d

    local now = wii.time()
    if now - report_t >= 3 then
      log(string.format("%s | %.1f fps | logic %.1f ms | gpu wait %.1f ms | image draws %d",
        state_name(), n_frames / (now - report_t), n_logic / n_frames * 1000,
        n_gpu / n_frames, n_draws / n_frames))
      log(string.format("    update %.1f ms | draw %.1f ms", n_upd / n_frames * 1000, n_drw / n_frames * 1000))
      log("    " .. mem_line())
      if rawget(_G, "snd") then
        local f, u, m, kb, nv = snd.stats()
        log(string.format("    sound: %d stream reads, %d gapless hand-overs, %d restarts (gaps), slowest read %d ms, cached %d KB, %d voices",
          f, u % 100000, math.floor(u / 100000), m, kb, nv))
      end
      gfx_timing_report()
      if love._fx_report then
        local fx = love._fx_report(n_frames)
        if fx then log("    card effects drawn per frame: " .. fx) end
      end
      if PROFILE then prof_report() end
      report_t, n_frames, n_logic, n_gpu, n_draws = now, 0, 0, 0, 0
      n_upd, n_drw = 0, 0
    end
  end
end

-- ---------------------------------------------------------------------------
splash_frame()
local ok, err = xpcall(function()
  load_game()
  run_frames()
end, traceback_handler)

if not ok then
  log_error(err)
  show_error_screen(err)
else
  log("exit requested")
end
