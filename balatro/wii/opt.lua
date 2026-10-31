-- opt.lua
-- Speed patches for the Wii. Loaded by play.lua after the game has started.
-- Every patch keeps the behaviour of the original game function, only cheaper.

local lg = love.graphics

-- the original functions, kept so that the loading transition can run exactly like the original game
local ORIG = {
  move_xy = Moveable and Moveable.move_xy, move_r = Moveable and Moveable.move_r,
  move_scale = Moveable and Moveable.move_scale,
  p_update = Particles and Particles.update, p_draw = Particles and Particles.draw, p_move = Particles and Particles.move,
  draw_shader = Sprite and Sprite.draw_shader, prep_draw = prep_draw,
  align = DynaText and DynaText.align_letters, ui_update = UIElement and UIElement.update,
}

-- tuning knobs
local PARTICLE_TIMER_MUL = 2.0   -- particles are created this many times slower
local PARTICLE_CAP = 20          -- at most this many particles per effect

-- 1) text that is not animated does not need its letters recalculated every frame
if DynaText and DynaText.align_letters then
  local orig_align = DynaText.align_letters
  DynaText.align_letters = function(self)
    local c = self.config
    local rm = G.SETTINGS.reduced_motion and true or false
    -- with Reduced Motion on, rotate / float / bump no longer change with time
    if self.pop_cycle or c.pop_out or c.pop_in or c.pulse or c.quiver
       or ((c.rotate or c.float or c.bump) and not rm) then
      self.opt_static = false
      return orig_align(self)
    end
    if self.opt_static and self.opt_rm == rm then
      local st = self.strings[self.focused_string]
      if st then self.string = st.string end
      return
    end
    self.opt_static = true
    self.opt_rm = rm
    return orig_align(self)
  end
end

-- 2) fewer particles, and cheaper code for the ones left
if Particles then
  local orig_init = Particles.init
  Particles.init = function(self, X, Y, W, H, config)
    if config then
      local c = {}
      for k, v in pairs(config) do c[k] = v end
      c.timer = (config.timer or 0.5) * PARTICLE_TIMER_MUL
      config = c
    end
    local r = orig_init(self, X, Y, W, H, config)
    if self.max > PARTICLE_CAP then self.max = PARTICLE_CAP end
    return r
  end

  local sin, cos, min, max = math.sin, math.cos, math.min, math.max
  local tremove = table.remove

  Particles.move = function(self, dt)
    if G.SETTINGS.paused and not self.created_on_pause then return end
    Moveable.move(self, dt)
    if self.timer_type ~= 'REAL' then dt = dt * G.SPEEDFACTOR end
    local ps = self.particles
    local lifespan, scale = self.lifespan, self.scale
    local sdt = scale * dt
    for i = #ps, 1, -1 do
      local p = ps[i]
      p.draw = true
      local e_vel = p.e_vel or dt * scale
      local e_prev = p.e_curr
      local age = p.age + dt
      p.age = age
      local e_curr = min(2 * min((age / lifespan) * scale, scale * ((lifespan - age) / lifespan)), scale)
      p.e_prev = e_prev
      p.e_curr = e_curr
      p.e_vel = (e_curr - e_prev) * sdt + (1 - sdt) * e_vel
      p.scale = e_curr
      if e_curr < 0 then
        tremove(ps, i)
      else
        local off = p.offset
        local vel = p.velocity
        off.x = off.x + vel * sin(p.dir) * dt
        off.y = off.y + vel * cos(p.dir) * dt
        p.facing = p.facing + p.r_vel * dt
        p.velocity = max(0, vel - vel * 0.07 * dt)
      end
    end
  end

  local g_push, g_pop, g_translate, g_rotate = lg.push, lg.pop, lg.translate, lg.rotate
  local g_rect, g_color = lg.rectangle, lg.setColor

  Particles.draw = function(self, alpha)
    alpha = (alpha or 1) * (1 - self.fade_alpha)
    prep_draw(self, 1)
    g_translate(self.T.w / 2, self.T.h / 2)
    for _, v in pairs(self.particles) do
      if v.draw then
        local c = v.colour
        local s = v.scale
        g_push()
        g_color(c[1], c[2], c[3], c[4] * alpha)
        g_translate(v.offset.x, v.offset.y)
        g_rotate(v.facing)
        g_rect('fill', -s / 2, -s / 2, s, s)
        g_pop()
      end
    end
    g_pop()
    add_to_drawhash(self)
    self:draw_boundingrect()
  end
end

-- 3) prep_draw runs for every drawn object: same maths, fewer table lookups
do
  local g_push, g_scale, g_translate, g_rotate = lg.push, lg.scale, lg.translate, lg.rotate
  prep_draw = function(m, scale, rotate, offset)
    local VT = m.VT
    g_push()
    g_scale(G.TILESCALE * G.TILESIZE)
    local lp = m.layered_parallax
    local par = m.parent
    local px = (lp and lp.x) or (par and par.layered_parallax and par.layered_parallax.x) or 0
    local py = (lp and lp.y) or (par and par.layered_parallax and par.layered_parallax.y) or 0
    g_translate(
      VT.x + VT.w / 2 + (offset and offset.x or 0) + px,
      VT.y + VT.h / 2 + (offset and offset.y or 0) + py)
    if VT.r ~= 0 or m.juice or rotate then g_rotate(VT.r + (rotate or 0)) end
    g_translate(-scale * VT.w * VT.scale / 2, -scale * VT.h * VT.scale / 2)
    g_scale(VT.scale * scale)
  end
end

-- 4) removing an object scanned whole lists from the start (very slow when a menu with
--    many cards closes). New objects sit at the END of the lists, so scan from the end.
do
  local tremove = table.remove
  local rfind = wii and wii.rfind     -- fast search written in C (new boot.dol)
  local function rem_rev(t, v)
    if rfind then
      local i = rfind(t, v)
      if i then tremove(t, i) end
      return
    end
    for i = #t, 1, -1 do
      if t[i] == v then tremove(t, i); return end
    end
  end

  local controller_targets = { "clicked", "focused", "dragging", "hovering", "released_on",
                               "cursor_down", "cursor_up", "cursor_hover" }

  Node.remove = function(self)
    rem_rev(G.I.POPUP, self)
    rem_rev(G.I.NODE, self)
    rem_rev(G.STAGE_OBJECTS[G.STAGE], self)
    if self.children then
      for _, v in pairs(self.children) do v:remove() end
    end
    local C = G.CONTROLLER
    for i = 1, #controller_targets do
      local slot = C[controller_targets[i]]
      if slot.target == self then slot.target = nil end
    end
    self.REMOVED = true
  end

  Moveable.remove = function(self)
    rem_rev(G.MOVEABLES, self)
    rem_rev(G.I.MOVEABLE, self)
    Node.remove(self)
  end

  local orig_sprite_remove = Sprite.remove
  Sprite.remove = function(self)
    if self.video then self.video:release() end
    for k, v in pairs(G.ANIMATIONS) do
      if v == self then table.remove(G.ANIMATIONS, k) end
    end
    rem_rev(G.I.SPRITE, self)
    Moveable.remove(self)
  end
end

-- 5) the Wii has no real shaders: do not send ten values to a dummy shader for every card.
--    The edition / seal / debuff passes only drew the card a second time without any effect:
--    skip them (effects come back later as cheap GX tricks).
local SKIP_SHADERS = { voucher = true, booster = true, gold_seal = true, negative_shine = true }
if Sprite and Sprite.draw_shader then
  Sprite.draw_shader = function(self, _shader, _shadow_height, _send, _no_tilt, other_obj, ms, mr, mx, my, custom_shader, tilt_shadow)
    if SKIP_SHADERS[_shader] then return end
    local _draw_major = self.role.draw_major or self
    local VT = self.VT
    if _shadow_height then
      VT.y = VT.y - _draw_major.shadow_parrallax.y * _shadow_height
      VT.x = VT.x - _draw_major.shadow_parrallax.x * _shadow_height
      VT.scale = VT.scale * (1 - 0.2 * _shadow_height)
    end
    local sh = G.SHADERS[_shader or 'dissolve']
    if custom_shader then
      if _send then
        for _, v in ipairs(_send) do
          sh:send(v.name, v.val or (v.func and v.func()) or v.ref_table[v.ref_value])
        end
      end
    elseif _shader == 'vortex' then
      sh:send('vortex_amt', G.TIMERS.REAL - (G.vortex_time or 0))
    else
      sh:send("dissolve", math.abs(_draw_major.dissolve or 0))
      sh:send("shadow", (not not _shadow_height))
      if _send then sh:send(_shader, _send) end
    end
    lg.setShader(sh, sh)
    if other_obj then self:draw_from(other_obj, ms, mr, mx, my) else self:draw_self() end
    lg.setShader()
    if _shadow_height then
      VT.y = VT.y + _draw_major.shadow_parrallax.y * _shadow_height
      VT.x = VT.x + _draw_major.shadow_parrallax.x * _shadow_height
      VT.scale = VT.scale / (1 - 0.2 * _shadow_height)
    end
  end
end

-- 6) cards compute a tilt angle for the shader every frame: no shader here, so skip it
if Card and Card.init then
  local orig_card_init = Card.init
  Card.init = function(self, ...)
    local r = orig_card_init(self, ...)
    self.ambient_tilt = nil
    return r
  end
end

-- 7) calmer, cheaper movement: cards and windows glide to their place without the springy
--    wobble (the wobble also keeps hundreds of objects "moving" for many extra frames)
local SNAPPY = true
local XY_RATE = 16
local SCALE_RATE = 16
if SNAPPY and Moveable then
  local abs, min = math.abs, math.min

  Moveable.move_xy = function(self, dt)
    local T, VT, vel = self.T, self.VT, self.velocity
    if T.x ~= VT.x or T.y ~= VT.y or abs(vel.x) > 0.01 or abs(vel.y) > 0.01 then
      local f = min(1, XY_RATE * dt)
      local dx, dy = (T.x - VT.x) * f, (T.y - VT.y) * f
      vel.x, vel.y = dx, dy
      self.STATIONARY = false
      VT.x = VT.x + dx
      VT.y = VT.y + dy
      if abs(VT.x - T.x) < 0.01 then VT.x = T.x; vel.x = 0 end
      if abs(VT.y - T.y) < 0.01 then VT.y = T.y; vel.y = 0 end
    end
  end

  Moveable.move_r = function(self, dt, vel)
    local des_r = self.T.r + (self.juice and self.juice.r * 2 or 0)
    if des_r ~= self.VT.r then
      self.STATIONARY = false
      self.VT.r = des_r
    end
    self.velocity.r = 0
  end

  Moveable.move_scale = function(self, dt)
    local VT = self.VT
    local des = self.T.scale + (self.zoom and ((self.states.drag.is and 0.1 or 0) + (self.states.hover.is and 0.05 or 0)) or 0) + (self.juice and self.juice.scale or 0)
    if des ~= VT.scale or abs(self.velocity.scale) > 0.001 then
      self.STATIONARY = false
      local d = des - VT.scale
      if abs(d) < 0.002 then
        VT.scale = des
      else
        VT.scale = VT.scale + d * min(1, SCALE_RATE * dt)
      end
      self.velocity.scale = 0
    end
  end
end

-- 8) the cursor collision test runs against every drawn node, every frame. When the cursor
--    has not moved it gives the same answer: repeat it only every third frame.
local COLLISION_THROTTLE = false   -- switched off: a tooltip started to flicker; test with true later
if COLLISION_THROTTLE and Controller and Controller.get_cursor_collision then
  local orig_collision = Controller.get_cursor_collision
  Controller.get_cursor_collision = function(self, cursor_trans)
    local last = self.opt_cursor
    local moved = (not last) or math.abs(last.x - cursor_trans.x) > 0.05 or math.abs(last.y - cursor_trans.y) > 0.05
    self.opt_skip = (self.opt_skip or 0) + 1
    if moved or self.opt_skip >= 3 or self.dragging.target or self.cursor_down.target
       or self.L_cursor_queue or self.R_cursor_queue or self.interrupt.focus then
      self.opt_cursor = self.opt_cursor or {}
      self.opt_cursor.x, self.opt_cursor.y = cursor_trans.x, cursor_trans.y
      self.opt_skip = 0
      return orig_collision(self, cursor_trans)
    end
  end
end

-- 9) particles (the stars behind the pack screens, sparkles...) cost time and are only decoration
local PARTICLES_OFF = true
if PARTICLES_OFF and Particles then
  Particles.update = function() end
  Particles.draw = function() end
  Particles.move = function(self, dt)
    if G.SETTINGS.paused and not self.created_on_pause then return end
    Moveable.move(self, dt)
  end
end

-- 10) UIElement:update keeps a debug counter of every callback it runs: not needed
if UIElement and UIElement.update then
  UIElement.update = function(self, dt)
    local config = self.config
    if config.button_delay then
      config.button_temp = config.button or config.button_temp
      config.button = nil
      config.button_delay_progress = (G.TIMERS.REAL - config.button_delay_start) / config.button_delay
      if G.TIMERS.REAL >= config.button_delay_end then config.button_delay = nil end
    end
    if config.button_temp and not config.button_delay then config.button = config.button_temp end
    if self.button_clicked then self.button_clicked = nil end
    if config.func then G.FUNCS[config.func](self) end
    local uit = self.UIT
    if uit == G.UIT.T then self:update_text() end
    if uit == G.UIT.O then self:update_object() end
    Node.update(self, dt)
  end
end

-- 11) the blind chip (top left): stays where it is, cannot be dragged, no animation
if Blind and Blind.init then
  local orig_blind_init = Blind.init
  Blind.init = function(self, ...)
    local r = orig_blind_init(self, ...)
    self.states.drag.can = false
    return r
  end
end
if AnimatedSprite and AnimatedSprite.animate then
  local orig_animate = AnimatedSprite.animate
  AnimatedSprite.animate = function(self, ...)
    local a = self.atlas
    if a and (a.name == 'blind_chips' or a.name == 'shop_sign') then
      if self.opt_animated then return end
      self.opt_animated = true            -- the first call sets up the picture, then it stays
    end
    return orig_animate(self, ...)
  end
end

-- 13) the cursor test (Node:collides_with_point) runs for every drawn node, every frame. Same maths and
--     the same answers as the original, but without the helper calls and the repeated sin / cos of
--     a container that is not rotated (its angle is 0 almost always).
if Node and Node.collides_with_point then
  local abs, cos, sin, pi = math.abs, math.cos, math.sin, math.pi
  local C0, S0 = cos(pi / 2), sin(pi / 2)
  Node.collides_with_point = function(self, point)
    local container = self.container
    if not container then return end
    local T = self.CT or self.T
    local _b = self.states.hover.is and G.COLLISION_BUFFER or 0
    local px, py = point.x, point.y
    if container ~= self then
      local cT = container.T
      local cr = cT.r
      if abs(cr) < 0.1 then
        px = px + (-cT.w / 2)
        py = py + (-cT.h / 2)
        local c, s
        if cr == 0 then c, s = C0, S0 else c, s = cos(cr + pi / 2), sin(cr + pi / 2) end
        local ox, oy = px, py
        px = -oy * c + ox * s
        py = oy * s + ox * c
        px = px + (cT.w / 2 - cT.x)
        py = py + (cT.h / 2 - cT.y)
      else
        px = px + (-cT.x)
        py = py + (-cT.y)
      end
    end
    if abs(T.r) < 0.1 then
      if px >= T.x - _b and py >= T.y - _b and px <= T.x + T.w + _b and py <= T.y + T.h + _b then
        return true
      end
    else
      local rc, rs = cos(T.r + pi / 2), sin(T.r + pi / 2)
      px, py = px - (T.x + 0.5 * (T.w)), py - (T.y + 0.5 * (T.h))
      local tx, ty = py * rc - px * rs, py * rs + px * rc
      px, py = tx + (T.x + 0.5 * (T.w)), ty + (T.y + 0.5 * (T.h))
      if px >= T.x - _b and py >= T.y - _b and px <= T.x + T.w + _b and py <= T.y + T.h + _b then
        return true
      end
    end
  end
end

-- 14) Moveable:move runs for every object every frame and called align_to_major first, which most of
--     the time found nothing to do. Now it is only called when the alignment really changed.
if Moveable and Moveable.move then
  Moveable.move = function(self, dt)
    if self.FRAME.MOVE >= G.FRAMES.MOVE then return end
    self.FRAME.OLD_MAJOR = self.FRAME.MAJOR
    self.FRAME.MAJOR = nil
    self.FRAME.MOVE = G.FRAMES.MOVE
    if not self.created_on_pause and G.SETTINGS.paused then return end

    local al = self.alignment
    if al then
      local po, off = al.prev_offset, al.offset
      if al.type ~= al.prev_type or po.x ~= off.x or po.y ~= off.y then self:align_to_major() end
    else
      self:align_to_major()
    end

    self.CALCING = nil
    local role = self.role
    if role.role_type == 'Glued' then
      if role.major then self:glue_to_major(role.major) end
    elseif role.role_type == 'Minor' and role.major then
      if role.major.FRAME.MOVE < G.FRAMES.MOVE then role.major:move(dt) end
      self.STATIONARY = role.major.STATIONARY
      if (not self.STATIONARY) or self.NEW_ALIGNMENT or
          self.config.refresh_movement or
          self.juice or
          role.xy_bond == 'Weak' or
          role.r_bond == 'Weak' then
        self.CALCING = true
        self:move_with_major(dt)
      end
    elseif role.role_type == 'Major' then
      self.STATIONARY = true
      self:move_juice(dt)
      self:move_xy(dt)
      self:move_r(dt, self.velocity)
      self:move_scale(dt)
      self:move_wh(dt)
      self:calculate_parrallax()
    end
    if al and al.lr_clamp then
      self:lr_clamp()
    end

    self.NEW_ALIGNMENT = false
  end
end

-- 15) SLEEP. Cards that stand still are put to sleep: the game loops skip them.
--     a) the draw pile (G.deck): cards are not drawn (only every 9th is) and nothing touches them while you
--        think: their move() and update() are skipped.
--     b) the consumable cards (G.consumeables, e.g. the many negative cards Perkeo makes): only move() is
--        skipped (update() still runs, it keeps their numbers up to date).
--     A sleeping card wakes up at once when anything about it changes (it is moved, flipped, touched,
--     highlighted, leaves its area, the pile shuffles or slides, the game state changes...). Needs the patched
--     game.lua loops (srcpatch.lua sets WII_SLEEP_LOOPS). An empty file sd:/balatro/nosleep.txt switches it off.
local DECK_SLEEP = true
do
  local f = io.open((rawget(_G, "BALATRO_ROOT") or "sd:/balatro") .. "/nosleep.txt", "rb")
  if f then f:close(); DECK_SLEEP = false end
end
if DECK_SLEEP and Game and Game.update then
  local abs = math.abs
  local EPS = 0.0005
  local ALLOWED = { center = true, front = true, back = true, shadow = true, floating_sprite = true }
  local WAIT_STATES = nil            -- filled at the first tick (G.STATES exists then)
  local sleepers, n_sleep = {}, 0
  local frame_n, state_seen, state_since, last_logged, log_count = 0, nil, 0, -1, 0
  local diag_count = 0
  local n_deck, n_cons, n_disc = 0, 0, 0
  local cons_diag = 0

  local function same(a, b)
    return abs(a.x - b.x) < EPS and abs(a.y - b.y) < EPS and abs(a.w - b.w) < EPS and abs(a.h - b.h) < EPS
       and abs(a.r - b.r) < EPS and abs((a.scale or 1) - (b.scale or 1)) < EPS
  end
  local function at_rest(o)
    local v = o.velocity
    return same(o.T, o.VT) and abs(v.x) < EPS and abs(v.y) < EPS and abs(v.r) < EPS and abs(v.scale) < EPS
       and not o.juice
  end
  -- the card itself: opt_asleep (deck: no move, no update) or opt_nomove (consumable: no move only);
  -- its picture children never need an update, they always get opt_asleep
  local function set_flag(c, val, kind)
    if kind == "cons" then c.opt_nomove = val else c.opt_asleep = val end
    local ch = c.children
    if ch then for _, o in pairs(ch) do if type(o) == "table" and o.states then o.opt_asleep = val end end end
  end
  local function all_rest(o)
    if not at_rest(o) then return false end
    local ch = o.children
    if ch then
      for k, c in pairs(ch) do
        if type(c) ~= "table" then return false end
        if not ALLOWED[k] then return false end
        if not c.states or not at_rest(c) then return false end
        if c.children and next(c.children) then return false end
      end
    end
    return true
  end
  local function touched(c)
    local st = c.states
    return st.drag.is or st.hover.is or st.focus.is or st.click.is or st.collide.is
  end
  local function deck_quiet(c)
    return not touched(c) and not c.pinch.x and not c.pinch.y and c.facing == "back" and c.sprite_facing == "back"
       and (c.dissolve == nil or c.dissolve == 0) and not c.REMOVED
       and G.deck and c.area == G.deck and G.deck.config and G.deck.config.type == "deck"
  end
  local function cons_quiet(c)
    return not touched(c) and not c.pinch.x and not c.pinch.y and c.facing == "front" and c.sprite_facing == "front"
       and (c.dissolve == nil or c.dissolve == 0) and not c.REMOVED and not c.highlighted and not c.juice
       and G.consumeables and c.area == G.consumeables
  end
  local function disc_quiet(c)
    return not touched(c) and not c.pinch.x and not c.pinch.y and c.facing == c.sprite_facing
       and (c.dissolve == nil or c.dissolve == 0) and not c.REMOVED
       and G.discard and c.area == G.discard
  end

  local function drop(i)
    local c = sleepers[i]
    set_flag(c, false, c.opt_kind)
    if c.opt_kind == "cons" then n_cons = n_cons - 1 elseif c.opt_kind == "disc" then n_disc = n_disc - 1 else n_deck = n_deck - 1 end
    table.remove(sleepers, i)
    n_sleep = n_sleep - 1
  end
  local function wake_kind(kind)
    for i = #sleepers, 1, -1 do
      if kind == nil or sleepers[i].opt_kind == kind then drop(i) end
    end
  end
  local function note()
    if n_sleep ~= last_logged and log_count < 150 and (n_sleep == 0 or last_logged <= 0) then
      log_count = log_count + 1
      if wii and wii.log then wii.log("sleep: " .. n_deck .. " deck cards + " .. n_disc .. " discard cards + " .. n_cons .. " consumable cards asleep") end
    end
    last_logged = n_sleep
  end
  local function fall_asleep(c, kind)
    local T = c.T
    c.opt_sx, c.opt_sy, c.opt_sr, c.opt_sw, c.opt_sh, c.opt_ss = T.x, T.y, T.r, T.w, T.h, T.scale
    c.opt_kind = kind
    set_flag(c, true, kind)
    sleepers[#sleepers + 1] = c
    n_sleep = n_sleep + 1
    if kind == "cons" then n_cons = n_cons + 1 elseif kind == "disc" then n_disc = n_disc + 1 else n_deck = n_deck + 1 end
  end

  local function tick()
    frame_n = frame_n + 1
    if not WII_SLEEP_LOOPS then return end
    if not WAIT_STATES and G.STATES then
      WAIT_STATES = {}
      for _, nm in ipairs({ "SELECTING_HAND", "SHOP", "BLIND_SELECT", "TAROT_PACK", "PLANET_PACK", "SPECTRAL_PACK",
                            "STANDARD_PACK", "BUFFOON_PACK" }) do
        local v = G.STATES[nm]
        if v then WAIT_STATES[v] = true end
      end
    end
    local deck = G.deck
    local cons = G.consumeables
    local run = G.STAGE == G.STAGES.RUN and not G.screenwipe and not G.SETTINGS.paused and deck and deck.cards
    if G.STATE ~= state_seen then state_seen = G.STATE; state_since = frame_n end
    -- 1) wake the ones that must move
    if n_sleep > 0 then
      if not run or frame_n - state_since < 1 then
        wake_kind(nil)
      else
        if n_deck > 0 then
          local sig_ok = deck.opt_sig_n == #deck.cards and deck.opt_sig_x == deck.T.x and deck.opt_sig_y == deck.T.y
                     and deck.opt_sig_s == deck.shuffle_amt
          if not sig_ok then wake_kind("deck") end
        end
        -- every frame only a cheap test (did the card's target position change, did it leave its area);
        -- deck cards: the fuller test every 4th frame. Consumable cards are touched by the player, so
        -- they get the fuller test every frame.
        for i = #sleepers, 1, -1 do
          local c = sleepers[i]
          local T = c.T
          local bad = T.x ~= c.opt_sx or T.y ~= c.opt_sy or T.r ~= c.opt_sr or T.w ~= c.opt_sw or T.h ~= c.opt_sh
                   or T.scale ~= c.opt_ss or c.REMOVED
          if not bad then
            if c.opt_kind == "cons" then bad = not cons_quiet(c)
            elseif c.opt_kind == "disc" then
              bad = c.area ~= G.discard or ((frame_n + i) % 4 == 0 and (c.juice or not disc_quiet(c)))
            else bad = c.area ~= deck or ((frame_n + i) % 4 == 0 and (c.juice or not deck_quiet(c))) end
          end
          if bad then drop(i) end
        end
      end
    end
    -- 2) now and then look for cards that can go to sleep
    if run and WAIT_STATES and WAIT_STATES[G.STATE] and frame_n - state_since >= 45 and frame_n % 15 == 0
       and not G.OVERLAY_MENU and not G.view_deck and not G.deck_preview then
      local cards = deck.cards
      local sig_same = deck.opt_sig_n == #cards and deck.opt_sig_x == deck.T.x and deck.opt_sig_y == deck.T.y
                   and deck.opt_sig_s == deck.shuffle_amt
      deck.opt_sig_n, deck.opt_sig_x, deck.opt_sig_y, deck.opt_sig_s = #cards, deck.T.x, deck.T.y, deck.shuffle_amt
      if sig_same and deck.shuffle_amt == 0 then
        for i = 1, #cards do
          local c = cards[i]
          if not c.opt_asleep and deck_quiet(c) and all_rest(c) then fall_asleep(c, "deck") end
        end
      end
      local disc = G.discard
      if disc and disc.cards then
        local dc = disc.cards
        for i = 1, #dc do
          local c = dc[i]
          if not c.opt_asleep and disc_quiet(c) and all_rest(c) then fall_asleep(c, "disc") end
        end
      end
      if cons and cons.cards then
        local cc = cons.cards
        for i = 1, #cc do
          local c = cc[i]
          if not c.opt_nomove and cons_quiet(c) and all_rest(c) then fall_asleep(c, "cons") end
        end
      end
    end
    -- diagnostics: if no deck card sleeps although the game waits, say which test fails (first card), few times
    if run and WAIT_STATES and WAIT_STATES[G.STATE] and n_deck == 0 and diag_count < 6
       and frame_n - state_since >= 200 and frame_n % 200 == 0 then
      local c = deck.cards[1]
      if c then
        local why = "none"
        if G.OVERLAY_MENU or G.view_deck or G.deck_preview then why = "overlay"
        elseif not deck_quiet(c) then
          local st = c.states
          why = string.format("quiet: drag %s hover %s focus %s click %s collide %s pinch %s facing %s/%s area %s dissolve %s",
            tostring(st.drag.is), tostring(st.hover.is), tostring(st.focus.is), tostring(st.click.is), tostring(st.collide.is),
            tostring(c.pinch.x), tostring(c.facing), tostring(c.sprite_facing), tostring(c.area == G.deck), tostring(c.dissolve))
        elseif not at_rest(c) then why = "not at rest"
        elseif not all_rest(c) then
          local keys = {}
          for k, ch in pairs(c.children) do keys[#keys + 1] = k .. (at_rest(ch) and "" or "(moving)") end
          why = "children: " .. table.concat(keys, ",")
        end
        diag_count = diag_count + 1
        if wii and wii.log then wii.log("deck sleep blocked: " .. why) end
      end
    end
    if run and WAIT_STATES and WAIT_STATES[G.STATE] and n_cons == 0 and cons_diag < 6 and cons and cons.cards
       and cons.cards[1] and frame_n - state_since >= 200 and frame_n % 200 == 100 then
      local c = cons.cards[1]
      local why = "none"
      if not cons_quiet(c) then
        local st = c.states
        why = string.format("quiet: drag %s hover %s focus %s click %s collide %s pinch %s facing %s/%s highlighted %s juice %s dissolve %s",
          tostring(st.drag.is), tostring(st.hover.is), tostring(st.focus.is), tostring(st.click.is), tostring(st.collide.is),
          tostring(c.pinch.x), tostring(c.facing), tostring(c.sprite_facing), tostring(c.highlighted), tostring(c.juice), tostring(c.dissolve))
      elseif not at_rest(c) then
        why = string.format("rest: T %.4f,%.4f,%.4f,%.4f,%.4f VT %.4f,%.4f,%.4f,%.4f,%.4f vel %.4f,%.4f,%.4f,%.4f reduced_motion %s",
          c.T.x, c.T.y, c.T.w, c.T.h, c.T.r, c.VT.x, c.VT.y, c.VT.w, c.VT.h, c.VT.r,
          c.velocity.x, c.velocity.y, c.velocity.r, c.velocity.scale, tostring(G.SETTINGS.reduced_motion))
      elseif not all_rest(c) then
        local keys = {}
        for k, ch in pairs(c.children) do keys[#keys + 1] = k .. (at_rest(ch) and "" or "(moving)") end
        why = "children: " .. table.concat(keys, ",")
      end
      cons_diag = cons_diag + 1
      if wii and wii.log then wii.log("consumable sleep blocked: " .. why) end
    end
    note()
  end

  local orig_update = Game.update
  Game.update = function(self, dt)
    tick()
    return orig_update(self, dt)
  end

  -- a flip starts an animation: the card must be awake for it
  if Card and Card.flip then
    local orig_flip = Card.flip
    Card.flip = function(self, ...)
      if self.opt_asleep or self.opt_nomove then
        for i = #sleepers, 1, -1 do if sleepers[i] == self then drop(i) break end end
        set_flag(self, false, "deck"); set_flag(self, false, "cons")
      end
      return orig_flip(self, ...)
    end
  end
end

-- 15b) many cards stacked in the consumable area (Perkeo makes one every shop): each one is only a thin
--      sliver of the pile, but every one costs 2 pictures x 2 layers per frame. Above CULL_MIN cards only about
--      CULL_TARGET of them are drawn (always the first, the last and any highlighted one). The cards that are not
--      drawn cannot be pointed at (the game only tests drawn cards). Set CULL_MIN to 999 to switch it off.
local CULL_MIN = 10
local CULL_TARGET = 8
do   -- an empty file sd:/balatro/nocull.txt switches this off
  local f = io.open((rawget(_G, "BALATRO_ROOT") or "sd:/balatro") .. "/nocull.txt", "rb")
  if f then f:close(); CULL_MIN = 100000 end
end
WII_CULL = function(area, i)
  if area ~= G.consumeables then return false end
  local n = #area.cards
  if n <= CULL_MIN then return false end
  if i == 1 or i == n then return false end
  local step = math.ceil(n / CULL_TARGET)
  return (i - 1) % step ~= 0
end

-- 16) Node:translate_container runs before nearly every drawing and looked up the same tables 12 times.
--     Same calculation in the same order (so the same numbers), with local variables.
if Node and Node.translate_container then
  local g_translate, g_rotate = lg.translate, lg.rotate
  Node.translate_container = function(self)
    local container = self.container
    if container and container ~= self then
      local T = container.T
      local w, h, x, y = T.w, T.h, T.x, T.y
      local ts, tz = G.TILESCALE, G.TILESIZE
      g_translate(w * ts * tz * 0.5, h * ts * tz * 0.5)
      g_rotate(T.r)
      g_translate(-w * ts * tz * 0.5 + x * ts * tz, -h * ts * tz * 0.5 + y * ts * tz)
    end
  end
end

-- 12) during the loading transition use the original functions, afterwards the fast ones again
do
  local PATCHED = {
    move_xy = Moveable.move_xy, move_r = Moveable.move_r, move_scale = Moveable.move_scale,
    p_update = Particles.update, p_draw = Particles.draw, p_move = Particles.move,
    draw_shader = Sprite.draw_shader, prep_draw = prep_draw, align = DynaText.align_letters,
    ui_update = UIElement.update,
  }
  function WII_OPT_WIPE(on)
    local s = on and ORIG or PATCHED
    Moveable.move_xy, Moveable.move_r, Moveable.move_scale = s.move_xy, s.move_r, s.move_scale
    Particles.update, Particles.draw, Particles.move = s.p_update, s.p_draw, s.p_move
    Sprite.draw_shader = s.draw_shader
    prep_draw = s.prep_draw
    DynaText.align_letters = s.align
    UIElement.update = s.ui_update
  end
end
