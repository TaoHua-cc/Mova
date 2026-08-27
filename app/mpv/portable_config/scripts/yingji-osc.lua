-- Yingji Apple TV-like OSC. It stays inside mpv, so every control affects real playback.
local mp = require 'mp'

local visible_until = 0
local last_mouse_x, last_mouse_y = -1, -1
local function now() return mp.get_time() end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function fmt(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  return string.format('%02d:%02d', math.floor(seconds / 60), seconds % 60)
end
local function esc(value)
  return tostring(value or ''):gsub('\\', '\\\\'):gsub('{', '\\{'):gsub('}', '\\}')
end
local function rect(x, y, w, h, color, alpha)
  return string.format('{\\an7\\pos(%.0f,%.0f)\\1c&H%s&\\1a&H%02X&\\p1}m 0 0 l %.0f 0 l %.0f %.0f l 0 %.0f{\\p0}', x, y, color, alpha or 0, w, w, h, h)
end
local function label(x, y, size, align, value, color, alpha)
  return string.format('{\\an%d\\pos(%.0f,%.0f)\\fs%.0f\\bord0\\shad0\\1c&H%s&\\1a&H%02X&}%s', align or 7, x, y, size, color or 'F8F8F8', alpha or 0, esc(value))
end
local function show(seconds)
  visible_until = now() + (seconds or 2.7)
end
local function is_visible()
  return now() < visible_until or mp.get_property_native('pause', false)
end
local function render()
  local width, height = mp.get_osd_size()
  if not width or width <= 0 or not is_visible() then mp.set_osd_ass(0, 0, ''); return end
  local duration = tonumber(mp.get_property_native('duration')) or 0
  local position = tonumber(mp.get_property_native('time-pos')) or 0
  local paused = mp.get_property_native('pause', false)
  local title = mp.get_property('media-title', '映迹')
  local edge, panel_h = math.max(36, width * .045), math.max(138, height * .19)
  local top_h, bar_y = math.max(92, height * .13), height - panel_h
  local progress_x, progress_w, progress_y = edge * 1.8, width - edge * 3.6, height - panel_h + 68
  local progress = duration > 0 and clamp(position / duration, 0, 1) or 0
  local center = width / 2
  local ass = ''
  ass = ass .. rect(0, 0, width, top_h, '111217', 58) .. rect(0, bar_y, width, panel_h, '111217', 44)
  ass = ass .. label(edge, 39, 42, 7, '×', 'F8F8F8', 0)
  ass = ass .. label(center, 30, 22, 8, title, 'F8F8F8', 0)
  ass = ass .. label(width - edge, 32, 17, 9, '音轨     字幕     全屏', 'F8F8F8', 8)
  ass = ass .. label(progress_x - 18, progress_y + 5, 18, 9, fmt(position), 'F8F8F8', 0)
  ass = ass .. label(progress_x + progress_w + 18, progress_y + 5, 18, 7, fmt(math.max(duration - position, 0)), 'F8F8F8', 0)
  ass = ass .. rect(progress_x, progress_y, progress_w, 7, 'BFC1C7', 80)
  ass = ass .. rect(progress_x, progress_y, math.max(3, progress_w * progress), 7, 'FFFFFF', 0)
  ass = ass .. rect(progress_x + progress_w * progress - 6, progress_y - 3, 12, 12, 'FFFFFF', 0)
  ass = ass .. label(center - 225, height - 43, 28, 8, '↶ 10', 'F8F8F8', 0)
  ass = ass .. label(center - 74, height - 43, 34, 8, paused and '▶' or 'Ⅱ', 'FFFFFF', 0)
  ass = ass .. label(center + 120, height - 43, 28, 8, '10 ↷', 'F8F8F8', 0)
  mp.set_osd_ass(width, height, ass)
end
local function hit(x, y, left, top, right, bottom) return x >= left and x <= right and y >= top and y <= bottom end
local function click()
  local width, height = mp.get_osd_size()
  local x, y = mp.get_mouse_pos()
  if not x or not y then return end
  if not is_visible() then show(); return end
  local edge, panel_h = math.max(36, width * .045), math.max(138, height * .19)
  local progress_x, progress_w, progress_y = edge * 1.8, width - edge * 3.6, height - panel_h + 68
  local center = width / 2
  if hit(x, y, 0, 0, edge * 2, 86) then mp.commandv('quit')
  elseif hit(x, y, progress_x, progress_y - 22, progress_x + progress_w, progress_y + 28) then
    local duration = tonumber(mp.get_property_native('duration')) or 0
    if duration > 0 then mp.commandv('seek', duration * clamp((x - progress_x) / progress_w, 0, 1), 'absolute') end
  elseif hit(x, y, center - 125, height - 98, center - 20, height) then mp.commandv('seek', -10, 'relative')
  elseif hit(x, y, center - 20, height - 98, center + 20, height) then mp.commandv('cycle', 'pause')
  elseif hit(x, y, center + 20, height - 98, center + 140, height) then mp.commandv('seek', 10, 'relative')
  elseif hit(x, y, width - edge * 6, 0, width - edge * 4, 86) then mp.commandv('cycle', 'audio')
  elseif hit(x, y, width - edge * 4, 0, width - edge * 2, 86) then mp.commandv('cycle', 'sub')
  elseif hit(x, y, width - edge * 2, 0, width, 86) then mp.commandv('cycle', 'fullscreen')
  else show() end
  show()
end

mp.observe_property('mouse-pos', 'native', function(_, value)
  if value and (value.x ~= last_mouse_x or value.y ~= last_mouse_y) then
    last_mouse_x, last_mouse_y = value.x, value.y
    show()
  end
end)
mp.observe_property('time-pos', 'native', render)
mp.observe_property('pause', 'native', function() show(); render() end)
mp.add_forced_key_binding('MBTN_LEFT', 'yingji-osc-click', click)
mp.add_key_binding('ESC', 'yingji-osc-close', function() mp.commandv('quit') end)
mp.add_periodic_timer(.1, render)
mp.register_event('file-loaded', function() show(3.5); render() end)
