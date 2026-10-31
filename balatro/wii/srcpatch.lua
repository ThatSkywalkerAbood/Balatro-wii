-- srcpatch.lua
-- Small text patches applied to the game's own Lua files WHILE they are loaded
-- (the files on the SD card are not changed). Loaded by play.lua before the game starts.
-- Each patch: { exact old text, new text, replace_all }

local ROOT = rawget(_G, "BALATRO_ROOT") or "sd:/balatro"
local SRC = ROOT .. "/src/"
local log = (wii and wii.log) or print

local SCALE_MOD = "0.07 + 0.02*math.sin(1.8*G.TIMERS.REAL) + 0.00*math.sin((G.TIMERS.REAL - math.floor(G.TIMERS.REAL))*math.pi*14)*(1 - (G.TIMERS.REAL - math.floor(G.TIMERS.REAL)))^3"
local ROTATE_MOD = "0.05*math.sin(1.219*G.TIMERS.REAL) + 0.00*math.sin((G.TIMERS.REAL)*math.pi*5)*(1 - (G.TIMERS.REAL - math.floor(G.TIMERS.REAL)))^2"

local PATCHES = {
  card = {
    -- Hologram and the soul / legendary jokers: the face sticks to the card, no floating or dancing
    { SCALE_MOD, "0", true },
    { ROTATE_MOD, "0", true },
    { "0.1 + 0.03*math.sin(1.8*G.TIMERS.REAL)", "0.1", true },
    -- every new card scanned all ~250 centers to find its key: the center already knows it
    { "if center == v then self.config.center_key = k end",
      "if center.key then self.config.center_key = center.key; break end if center == v then self.config.center_key = k end", false },
  },
  blind = {
    -- the blind chip (top left): it stays still, and has no shadow copy
    { "0.02*math.sin(2*G.TIMERS.REAL+self.T.x)", "0", true },
    { "0.03*math.sin(0.666*G.TIMERS.REAL+self.T.x)", "0", true },
    { "0.03*math.sin(0.436*G.TIMERS.REAL+self.T.x)", "0", true },
    { "self.children.animatedSprite:draw_shader('dissolve', 0.1)", "", false },
  },
  ["engine/ui"] = {
    -- the white flash when the focus moves is back on the main menu screens (deck / stake choice), but off during a run
    { "local lw = 50*math.max(0, self.focus_timer - G.TIMERS.REAL + 0.3)^2", "local lw = (G.STAGE == G.STAGES.MAIN_MENU) and 50*math.max(0, self.focus_timer - G.TIMERS.REAL + 0.3)^2 or 0", false },
    { "local lw = 50*math.max(0, self.object_focus_timer - G.TIMERS.REAL + 0.3)^2", "local lw = (G.STAGE == G.STAGES.MAIN_MENU) and 50*math.max(0, self.object_focus_timer - G.TIMERS.REAL + 0.3)^2 or 0", false },
  },
  game = {
    -- cards of the draw pile can sleep (opt.lua): the move and update loops skip sleeping objects
    { "local move_dt = math.min(1/20, self.real_dt)", "WII_SLEEP_LOOPS = true\n        local move_dt = math.min(1/20, self.real_dt)", false },
    { "            if v.FRAME.MOVE < G.FRAMES.MOVE then v:move(move_dt) end",
      "            if v.FRAME.MOVE < G.FRAMES.MOVE and not v.opt_asleep and not v.opt_nomove then v:move(move_dt) end", false },
    { "            v:update(dt*self.SPEEDFACTOR)\n            v.states.collide.is = false",
      "            if not v.opt_asleep then v:update(dt*self.SPEEDFACTOR) end\n            v.states.collide.is = false", false },
  },
  cardarea = {
    -- many stacked consumable cards: only some of them are drawn (see WII_CULL in opt.lua)
    { "                    if not self.cards[i].highlighted then",
      "                    if not self.cards[i].highlighted and not (WII_CULL and WII_CULL(self, i)) then", false },
  },
  ["functions/UI_definitions"] = {
    -- no white flash on the hand card that gets the focus
    { "playing_card_colour[4] = 1.5", "playing_card_colour[4] = 0", false },
    { "if G.hand and card.area == G.hand then ease_value(playing_card_colour, 4, -1.5, nil, 'REAL',nil, 0.2, 'quad') end", "", false },
    -- no Options / Run Info buttons on the screen (PLUS and MINUS do the same)
    { '{n=G.UIT.C, config={align = "cm"}, nodes=contents.buttons},', "", false },
    -- the Quit button of the PC version on the main menu (it leaves to the Wii Menu)
    { "G.F_QUIT_BUTTON and", "true and", true },
    -- the Copy buttons next to the seed: the Wii has no clipboard, they do nothing
    { "UIBox_button({col = true, button = 'copy_seed', label = {localize('b_copy')}, colour = G.C.BLUE, scale = 0.3, minw = 1.3, minh = 0.5,}),", "", false },
    { "UIBox_button({button = 'copy_seed', label = {localize('b_copy')}, colour = G.C.BLUE, scale = 0.3, minw = 2.3, minh = 0.4,}),", "", false },
    { "UIBox_button({button = 'copy_seed', label = {localize('b_copy')}, colour = G.C.BLUE, scale = 0.3, minw = 2.3, minh = 0.4, focus_args = {nav = 'wide'}}),", "", false },
  },
}

local function apply(name, text)
  local list = PATCHES[name]
  if not list then return text end
  for i = 1, #list do
    local old, new, all = list[i][1], list[i][2], list[i][3]
    local count = 0
    local pos = 1
    while true do
      local a, b = text:find(old, pos, true)
      if not a then break end
      text = text:sub(1, a - 1) .. new .. text:sub(b + 1)
      pos = a + #new
      count = count + 1
      if not all then break end
    end
    if count == 0 then log("patch " .. name .. " #" .. i .. " did not match") end
  end
  return text
end

table.insert(package.loaders, 2, function(name)
  if not PATCHES[name] then return nil end          -- everything else loads the normal way
  local path = SRC .. name .. ".lua"
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  local fn, err = loadstring(apply(name, text), "@" .. path)
  if not fn then error(err) end
  return fn
end)

return { apply = apply, PATCHES = PATCHES }
