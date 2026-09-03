--[[
THESIS: Playback Console keeps the film dominant while every control remains readable at a glance.
OWN-WORLD: near-black cinema canvas, one structural-glass console, white focus, cool secondary type, coherent line icons.
STORY: identify the episode, scrub or transport, then open resource, audio, danmaku, subtitle, speed, chapter, or episode context in place.
FIRST VIEWPORT: quiet title row; scrubber on the console edge; metadata left, transport centered, utilities right; sheets open upward from their trigger.
FORM: approved Playback Console comp `.impeccable/mocks/player-c-playback-console.png`, seed f25f08df.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, and DESIGN.md.
]]
local mp = require 'mp'
local assdraw = require 'mp.assdraw'
local utils = require 'mp.utils'

local visible_until, panel_mode, panel_offset, panel_focus, pending_seek, panel_opened_at = 0, 'audio', 0, 1, nil, 0
local panel_nav_focus, panel_section_focus = false, 1
local render_logged = false
local mouse_x, mouse_y, overlay_signature = -1, -1, ''
local mouse_down, volume_dragging, progress_dragging = false, false, false
local pending_overlay_cards = nil
local overlay_ids = {}
local logo_overlay_signature=''
local overlay_available = true
local intro_skipped,outro_skipped=false,false
mp.msg.info('[yingji_osc] custom playback controls loaded')
local set_panel_key_bindings

-- Native bitmap overlays are optional (some mpv builds omit overlay commands).
-- Never let a missing overlay backend take down the ASS control layer.
local function safe_overlay_command(...)
  if not overlay_available then return false end
  local ok,err=pcall(mp.commandv,...)
  if not ok then overlay_available=false; mp.msg.warn('[yingji_osc] overlay unavailable: '..tostring(err)) end
  return ok
end

local function load_state()
  local file = mp.get_opt and mp.get_opt('yj-state-file') or nil
  if not file or file == '' then return {} end
  local handle = io.open(file, 'rb'); if not handle then return {} end
  local raw = handle:read('*a'); handle:close()
  local ok, data = pcall(utils.parse_json, raw)
  return ok and type(data) == 'table' and data or {}
end

local state = load_state()
local headless = mp.get_opt and mp.get_opt('yj-headless') == 'yes'
local function now() return mp.get_time() end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function esc(value) return tostring(value or ''):gsub('\\', '\\\\'):gsub('{', '\\{'):gsub('}', '\\}'):gsub('[\r\n]+', ' ') end
local function fmt(value)
  value = math.max(0, math.floor(tonumber(value) or 0))
  return value >= 3600 and string.format('%d:%02d:%02d', math.floor(value / 3600), math.floor(value % 3600 / 60), value % 60) or string.format('%02d:%02d', math.floor(value / 60), value % 60)
end
local function rate(value)
  value = tonumber(value) or 0
  if value <= 0 then return '网络 --' end
  if value >= 1000000 then return string.format('网络 %.1f MB/s', value / 1000000) end
  return string.format('网络 %.0f KB/s', value / 1000)
end
local function hit(x,y,left,top,right,bottom) return x >= left and x <= right and y >= top and y <= bottom end
local function show(seconds) visible_until = now() + (seconds or 4.2) end
-- Controls stay visible briefly after input, then collapse over the video.
-- An open sheet keeps the console alive until the user closes it.
local function visible() return panel_mode ~= nil or now() < visible_until end

local function text(ass,x,y,size,align,value,color,alpha,bold)
  ass:new_event(); ass:pos(x,y)
  ass:append(string.format('{\\an%d\\fs%.0f\\bord0\\shad0\\1c&H%s&\\1a&H%02X&%s}%s', align or 7, size, color or 'FFFFFF', alpha or 0, bold and '\\b1' or '', esc(value)))
end
local function clipped_text(ass,x,y,size,align,value,color,alpha,bold,left,top,right,bottom)
  ass:new_event(); ass:pos(x,y)
  ass:append(string.format('{\\an%d\\fs%.0f\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\clip(%.0f,%.0f,%.0f,%.0f)%s}%s', align or 7, size, color or 'FFFFFF', alpha or 0, left, top, right, bottom, bold and '\\b1' or '', esc(value)))
end
local function rect(ass,x,y,w,h,color,alpha)
  ass:new_event(); ass:pos(0,0); ass:append(string.format('{\\an7\\bord0\\shad0\\1c&H%s&\\1a&H%02X&}',color or '11151C',alpha or 0))
  ass:draw_start(); ass:rect_cw(x,y,x+w,y+h); ass:draw_stop()
end
local function circle(ass,cx,cy,r,color,alpha)
  local k=r*.55228475
  ass:new_event(); ass:pos(0,0); ass:append(string.format('{\\an7\\bord0\\shad0\\1c&H%s&\\1a&H%02X&}',color or 'FFFFFF',alpha or 0)); ass:draw_start()
  ass:move_to(cx,cy-r); ass:bezier_curve(cx+k,cy-r,cx+r,cy-k,cx+r,cy); ass:bezier_curve(cx+r,cy+k,cx+k,cy+r,cx,cy+r)
  ass:bezier_curve(cx-k,cy+r,cx-r,cy+k,cx-r,cy); ass:bezier_curve(cx-r,cy-k,cx-k,cy-r,cx,cy-r); ass:draw_stop()
end
local function roundrect(ass,x,y,w,h,r,color,alpha)
  r=math.max(0,math.min(r or 0,w/2,h/2)); local k=r*.55228475
  ass:new_event(); ass:pos(0,0); ass:append(string.format('{\\an7\\bord0\\shad0\\1c&H%s&\\1a&H%02X&}',color or '11151C',alpha or 0)); ass:draw_start()
  ass:move_to(x+r,y); ass:line_to(x+w-r,y); ass:bezier_curve(x+w-r+k,y,x+w,y+r-k,x+w,y+r); ass:line_to(x+w,y+h-r)
  ass:bezier_curve(x+w,y+h-r+k,x+w-r+k,y+h,x+w-r,y+h); ass:line_to(x+r,y+h); ass:bezier_curve(x+r-k,y+h,x,y+h-r+k,x,y+h-r)
  ass:line_to(x,y+r); ass:bezier_curve(x,y+r-k,x+r-k,y,x+r,y); ass:draw_stop()
end
local function polygon(ass,points,color,alpha)
  ass:new_event(); ass:pos(0,0); ass:append(string.format('{\\an7\\bord0\\shad0\\1c&H%s&\\1a&H%02X&}',color or 'FFFFFF',alpha or 0)); ass:draw_start()
  ass:move_to(points[1],points[2]); for index=3,#points,2 do ass:line_to(points[index],points[index+1]) end; ass:draw_stop()
end
-- One material is reserved for a sheet. Buttons stay bare so the video remains
-- the dominant surface; selection is communicated by a quiet luminance lift.
local function glass(ass,x,y,w,h,r)
  roundrect(ass,x+3,y+9,w,h,r,'000000',126)
  roundrect(ass,x,y,w,h,r,'F7FAFF',194)
  roundrect(ass,x+1,y+1,w-2,h-2,math.max(1,r-1),'111923',38)
  roundrect(ass,x+1,y+1,w-2,1,1,'FFFFFF',202)
end
local function row_surface(ass,x,y,w,h,r,active,focused,hovered)
  if active then
    roundrect(ass,x,y,w,h,r,'F7FAFF',184)
    roundrect(ass,x+1,y+1,w-2,h-2,math.max(1,r-1),'DCEBFA',214)
  elseif focused then
    roundrect(ass,x,y,w,h,r,'F7FAFF',188)
    roundrect(ass,x+1,y+1,w-2,h-2,math.max(1,r-1),'17202C',58)
  elseif hovered then
    roundrect(ass,x,y,w,h,r,'F7FAFF',222)
  end
end
local function tooltip(ass,x,y,label)
  local width=math.max(58,#tostring(label)*12+26)
  roundrect(ass,x-width/2,y-28,width,24,12,'000000',74)
  roundrect(ass,x-width/2,y-28,width,24,12,'FFFFFF',210)
  text(ass,x,y-12,11,5,label,'FFFFFF',0,true)
end

local function dimensions()
  local value=mp.get_property_native('osd-dimensions') or {}; local w,h=tonumber(value.w),tonumber(value.h)
  if not w or not h or w <= 0 or h <= 0 then w,h=mp.get_osd_size() end
  return w,h
end
local function layout(w,h)
  local edge=math.max(24,math.floor(w*.018)); local rail_w=clamp(math.floor(w*.278),380,430); local main_w=w-rail_w
  local console_h=clamp(math.floor(h*.17),154,176); local console_y=h-edge-console_h
  return { edge=edge, rail_x=main_w, rail_w=rail_w, main_w=main_w, console_x=edge, console_y=console_y, console_w=main_w-edge*2, console_h=console_h, progress_y=console_y+26, meta_y=console_y+61, center_y=console_y+104, utility_y=console_y+139 }
end

local function line(ass,x,y,w,h,color) rect(ass,x,y,w,h,color or 'FFFFFF',0) end
local function stroke(ass,x1,y1,x2,y2,width,color,alpha)
  local dx,dy=x2-x1,y2-y1; local length=math.sqrt(dx*dx+dy*dy); if length<.01 then circle(ass,x1,y1,width/2,color,alpha); return end
  local half=width/2; local ox=-dy/length*half; local oy=dx/length*half
  polygon(ass,{x1+ox,y1+oy,x2+ox,y2+oy,x2-ox,y2-oy,x1-ox,y1-oy},color,alpha)
  circle(ass,x1,y1,half,color,alpha); circle(ass,x2,y2,half,color,alpha)
end
local function chevron(ass,cx,cy,direction,scale,color)
  local s=(scale or 1)*7; local sign=direction=='left' and -1 or 1
  stroke(ass,cx-sign*s,cy-s,cx+sign*s,cy,2*scale,color,0); stroke(ass,cx+sign*s,cy,cx-sign*s,cy+s,2*scale,color,0)
end
local function control_halo(ass,cx,cy,hovered,active,r)
  if not hovered and not active then return end
  r=r or 19
  circle(ass,cx+1,cy+3,r+3,'000000',185)
  circle(ass,cx,cy,r+1,'FFFFFF',active and 192 or 222)
  circle(ass,cx,cy,r,'1D222B',active and 52 or 86)
  circle(ass,cx,cy-r+1,r-3,'FFFFFF',214)
end
local function icon(ass,cx,cy,name,color,scale)
  color=color or 'F7F8FC'; scale=scale or 1; local s=scale; local sw=2*s
  if name=='play' then polygon(ass,{cx-5*s,cy-10*s,cx+10*s,cy,cx-5*s,cy+10*s},color,0)
  elseif name=='pause' then roundrect(ass,cx-7*s,cy-10*s,4*s,20*s,2*s,color,0); roundrect(ass,cx+3*s,cy-10*s,4*s,20*s,2*s,color,0)
  elseif name=='back' then chevron(ass,cx-3*s,cy,'left',s,color); stroke(ass,cx+8*s,cy-8*s,cx+8*s,cy+8*s,sw,color,0)
  elseif name=='forward' then chevron(ass,cx+3*s,cy,'right',s,color); stroke(ass,cx-8*s,cy-8*s,cx-8*s,cy+8*s,sw,color,0)
  elseif name=='prev' then stroke(ass,cx-9*s,cy-9*s,cx-9*s,cy+9*s,sw,color,0); chevron(ass,cx+1*s,cy,'left',s,color)
  elseif name=='next' then stroke(ass,cx+9*s,cy-9*s,cx+9*s,cy+9*s,sw,color,0); chevron(ass,cx-1*s,cy,'right',s,color)
  elseif name=='audio' or name=='volume' then polygon(ass,{cx-10*s,cy-4*s,cx-5*s,cy-4*s,cx+2*s,cy-10*s,cx+2*s,cy+10*s,cx-5*s,cy+4*s,cx-10*s,cy+4*s},color,0); stroke(ass,cx+7*s,cy-5*s,cx+10*s,cy,sw,color,0); stroke(ass,cx+10*s,cy,cx+7*s,cy+5*s,sw,color,0)
  elseif name=='resources' then for i=-1,1 do local y=cy+i*7*s; stroke(ass,cx-10*s,y,cx+10*s,y,sw,color,0); circle(ass,cx+(i==0 and 3 or (i<0 and -3 or 6))*s,y,2.8*s,color,0) end
  elseif name=='episodes' then for ix=-1,1,2 do for iy=-1,1,2 do roundrect(ass,cx+(ix*4-3)*s,cy+(iy*4-3)*s,6*s,6*s,2*s,color,0) end end
  elseif name=='danmaku' then stroke(ass,cx-9*s,cy-6*s,cx+9*s,cy-6*s,sw,color,0); stroke(ass,cx+9*s,cy-6*s,cx+9*s,cy+5*s,sw,color,0); stroke(ass,cx+9*s,cy+5*s,cx-3*s,cy+5*s,sw,color,0); stroke(ass,cx-3*s,cy+5*s,cx-7*s,cy+9*s,sw,color,0); stroke(ass,cx-7*s,cy+9*s,cx-7*s,cy+5*s,sw,color,0); stroke(ass,cx-9*s,cy+5*s,cx-9*s,cy-6*s,sw,color,0)
  elseif name=='info' then circle(ass,cx,cy,9*s,color,0); text(ass,cx,cy+5*s,13*s,5,'i','11151C',0,true)
  elseif name=='count' then circle(ass,cx,cy,9*s,color,0); text(ass,cx,cy+5*s,11*s,5,'#','11151C',0,true)
  elseif name=='source' then circle(ass,cx-7*s,cy-5*s,2.5*s,color,0); circle(ass,cx+7*s,cy-5*s,2.5*s,color,0); circle(ass,cx,cy+7*s,2.5*s,color,0); stroke(ass,cx-5*s,cy-3*s,cx-1*s,cy+5*s,sw,color,0); stroke(ass,cx+5*s,cy-3*s,cx+1*s,cy+5*s,sw,color,0); stroke(ass,cx-4*s,cy-5*s,cx+4*s,cy-5*s,sw,color,0)
  elseif name=='eye' then stroke(ass,cx-11*s,cy,cx-5*s,cy-6*s,sw,color,0); stroke(ass,cx-5*s,cy-6*s,cx+5*s,cy-6*s,sw,color,0); stroke(ass,cx+5*s,cy-6*s,cx+11*s,cy,sw,color,0); stroke(ass,cx+11*s,cy,cx+5*s,cy+6*s,sw,color,0); stroke(ass,cx+5*s,cy+6*s,cx-5*s,cy+6*s,sw,color,0); stroke(ass,cx-5*s,cy+6*s,cx-11*s,cy,sw,color,0); circle(ass,cx,cy,3*s,color,0)
  elseif name=='density' then stroke(ass,cx-10*s,cy-7*s,cx+10*s,cy-7*s,sw,color,0); stroke(ass,cx-10*s,cy,cx+7*s,cy,sw,color,0); stroke(ass,cx-10*s,cy+7*s,cx+3*s,cy+7*s,sw,color,0)
  elseif name=='refresh' then chevron(ass,cx+6*s,cy-7*s,'right',.55*s,color); stroke(ass,cx-8*s,cy-5*s,cx+6*s,cy-5*s,sw,color,0); chevron(ass,cx-6*s,cy+7*s,'left',.55*s,color); stroke(ass,cx+8*s,cy+5*s,cx-6*s,cy+5*s,sw,color,0)
  elseif name=='speed' then circle(ass,cx,cy,9*s,color,0); stroke(ass,cx,cy,cx+5*s,cy-5*s,sw,'11151C',0)
  elseif name=='layout' then stroke(ass,cx-10*s,cy-7*s,cx+10*s,cy-7*s,sw,color,0); stroke(ass,cx-10*s,cy,cx+10*s,cy,sw,color,0); stroke(ass,cx-10*s,cy+7*s,cx+10*s,cy+7*s,sw,color,0)
  elseif name=='subtitle' then roundrect(ass,cx-10*s,cy-8*s,20*s,16*s,4*s,color,0); text(ass,cx,cy+4*s,8*s,5,'CC','11151C',0,true)
  elseif name=='chapters' then stroke(ass,cx-8*s,cy-10*s,cx-8*s,cy+10*s,sw,color,0); stroke(ass,cx-7*s,cy-9*s,cx+9*s,cy-5*s,sw,color,0); stroke(ass,cx+9*s,cy-5*s,cx-7*s,cy-1*s,sw,color,0)
  elseif name=='check' then stroke(ass,cx-9*s,cy,cx-3*s,cy+6*s,sw,color,0); stroke(ass,cx-3*s,cy+6*s,cx+10*s,cy-8*s,sw,color,0)
  elseif name=='pin' then stroke(ass,cx-8*s,cy-8*s,cx+8*s,cy-8*s,sw,color,0); stroke(ass,cx-5*s,cy-8*s,cx-5*s,cy+1*s,sw,color,0); stroke(ass,cx+5*s,cy-8*s,cx+5*s,cy+1*s,sw,color,0); stroke(ass,cx-8*s,cy+1*s,cx+8*s,cy+1*s,sw,color,0); stroke(ass,cx,cy+1*s,cx,cy+10*s,sw,color,0)
  elseif name=='min' then stroke(ass,cx-8*s,cy+4*s,cx+8*s,cy+4*s,sw,color,0)
  elseif name=='max' then stroke(ass,cx-8*s,cy-8*s,cx+8*s,cy-8*s,sw,color,0); stroke(ass,cx+8*s,cy-8*s,cx+8*s,cy+8*s,sw,color,0); stroke(ass,cx+8*s,cy+8*s,cx-8*s,cy+8*s,sw,color,0); stroke(ass,cx-8*s,cy+8*s,cx-8*s,cy-8*s,sw,color,0)
  elseif name=='close' then stroke(ass,cx-7*s,cy-7*s,cx+7*s,cy+7*s,sw,color,0); stroke(ass,cx+7*s,cy-7*s,cx-7*s,cy+7*s,sw,color,0)
  elseif name=='settings' then circle(ass,cx,cy,8*s,color,0); circle(ass,cx,cy,3*s,color,0); for _,point in ipairs({{-10,0},{10,0},{0,-10},{0,10}}) do circle(ass,cx+point[1]*s,cy+point[2]*s,2*s,color,0) end
  elseif name=='picture' then roundrect(ass,cx-10*s,cy-8*s,20*s,16*s,3*s,color,0); circle(ass,cx-4*s,cy-3*s,2*s,color,0); stroke(ass,cx-8*s,cy+5*s,cx-2*s,cy,sw,color,0); stroke(ass,cx-2*s,cy,cx+2*s,cy+4*s,sw,color,0); stroke(ass,cx+2*s,cy+4*s,cx+7*s,cy-2*s,sw,color,0)
  elseif name=='loop' then stroke(ass,cx-9*s,cy-5*s,cx+8*s,cy-5*s,sw,color,0); chevron(ass,cx+6*s,cy-5*s,'right',.45*s,color); stroke(ass,cx+9*s,cy+5*s,cx-8*s,cy+5*s,sw,color,0); chevron(ass,cx-6*s,cy+5*s,'left',.45*s,color)
  elseif name=='capture' then roundrect(ass,cx-10*s,cy-7*s,20*s,15*s,3*s,color,0); circle(ass,cx,cy+.5*s,4*s,color,0); roundrect(ass,cx-4*s,cy-10*s,8*s,4*s,1*s,color,0)
  elseif name=='fullscreen' then stroke(ass,cx-9*s,cy-3*s,cx-9*s,cy-9*s,sw,color,0); stroke(ass,cx-9*s,cy-9*s,cx-3*s,cy-9*s,sw,color,0); stroke(ass,cx+9*s,cy-3*s,cx+9*s,cy-9*s,sw,color,0); stroke(ass,cx+9*s,cy-9*s,cx+3*s,cy-9*s,sw,color,0); stroke(ass,cx-9*s,cy+3*s,cx-9*s,cy+9*s,sw,color,0); stroke(ass,cx-9*s,cy+9*s,cx-3*s,cy+9*s,sw,color,0); stroke(ass,cx+9*s,cy+3*s,cx+9*s,cy+9*s,sw,color,0); stroke(ass,cx+9*s,cy+9*s,cx+3*s,cy+9*s,sw,color,0)
  end
end

local function top_buttons(w,l)
  local x=w-l.edge-18; return {{name='close',x=x},{name='max',x=x-48},{name='min',x=x-96},{name='pin',x=x-144}}
end
local utility_names={'subtitle','danmaku','settings','fullscreen'}
local utility_labels={subtitle='字幕',danmaku='弹幕',settings='播放设置',fullscreen='全屏'}
local utility_widths={subtitle=44,danmaku=44,settings=44,fullscreen=44}
local PANEL_ROWS=6
local function utility_buttons(w,l)
  local compact=w<1480; local right=l.console_x+l.console_w-24; local list={}
  for index=#utility_names,1,-1 do local name=utility_names[index]; local width=compact and 44 or utility_widths[name]; right=right-width; table.insert(list,1,{name=name,x=right,y=l.utility_y-18,w=width,h=36,compact=compact}); right=right-7 end
  return list,right
end
local function upper_controls(w,l)
  local right=l.console_x+l.console_w-24
  return {name='volume',x=right-142,y=l.console_y+55,w=142,h=34}
end
local function transport_buttons(w,l)
  local center=l.console_x+l.console_w/2; return {{name='prev',x=center-116},{name='back',x=center-58},{name='pause',x=center},{name='forward',x=center+58},{name='next',x=center+116}}
end

local function resources() return type(state.resourceOptions)=='table' and state.resourceOptions or {} end
local function episodes() return type(state.episodeOptions)=='table' and state.episodeOptions or {} end
local function tracks(kind)
  local result={}
  for _,track in ipairs(mp.get_property_native('track-list') or {}) do local danmaku=kind=='sub' and tostring(track['external-filename'] or ''):find('yingji%-danmaku'); if track.type==kind and not danmaku then result[#result+1]=track end end
  return result
end
local function track_detail(track)
  local parts={}; if track.lang and track.lang~='' then parts[#parts+1]=track.lang end; if track.codec and track.codec~='' then parts[#parts+1]=track.codec:upper() end; if track['demux-channel-count'] then parts[#parts+1]=tostring(track['demux-channel-count'])..' 声道' end; if track.default then parts[#parts+1]='默认' end; if track.forced then parts[#parts+1]='强制' end
  return table.concat(parts,' · ')
end
local function track_signature(track)
  if not track then return nil end
  return { lang=tostring(track.lang or ''), title=tostring(track.title or ''), codec=tostring(track.codec or ''), channels=tonumber(track['demux-channel-count']) or 0 }
end
local function track_matches(track,signature)
  if type(signature)~='table' then return false end
  local current=track_signature(track)
  if current.title~='' and current.title==tostring(signature.title or '') then return true end
  return current.lang~='' and current.lang==tostring(signature.lang or '') and (current.codec=='' or current.codec==tostring(signature.codec or ''))
end
local function save_media_preference(key,value,reload)
  if not state.playerPreferenceKey or state.playerPreferenceKey=='' then return end
  mp.set_property('user-data/yj-player-action',utils.format_json({type='media-preference',preferenceKey=state.playerPreferenceKey,key=key,value=value,reload=reload or false,context=state.danmakuContext}))
end
local function danmaku_track()
  for _,track in ipairs(mp.get_property_native('track-list') or {}) do if track.type=='sub' and tostring(track['external-filename'] or ''):find('yingji%-danmaku') then return track end end
end
local function apply_saved_track(kind,preference)
  if kind=='sub' and preference=='off' then mp.set_property('sid','no'); return end
  if type(preference)~='table' then return end
  for _,track in ipairs(tracks(kind)) do
    if track_matches(track,preference) then mp.set_property(kind=='audio' and 'aid' or 'sid',tostring(track.id)); if kind=='sub' then mp.set_property('sub-visibility','yes') end; return end
  end
end
local settings_sections={
  {mode='audio',label='声音',icon='audio'},
  {mode='subtitle',label='字幕',icon='subtitle'}, {mode='danmaku',label='弹幕',icon='danmaku'},
  {mode='playback',label='播放',icon='speed'}, {mode='picture',label='画面',icon='picture'},
  {mode='chapters',label='章节',icon='chapters'}, {mode='info',label='诊断',icon='info'}
}
local function settings_section_index(mode)
  for index,item in ipairs(settings_sections) do if item.mode==mode then return index end end
  return 1
end
local function is_settings_mode(mode)
  for _,item in ipairs(settings_sections) do if item.mode==mode then return true end end
  return false
end
local function cycle_property(property,values,preference)
  local current=tonumber(mp.get_property_native(property)) or tonumber(state[preference]) or values[1]
  local index=1; for i,value in ipairs(values) do if math.abs(value-current)<.01 then index=i end end
  local next_value=values[index%#values+1]; mp.set_property_native(property,next_value); state[preference]=next_value; save_media_preference(preference,next_value)
end
local function save_ui_preference(key,value)
  mp.set_property('user-data/yj-player-action',utils.format_json({type='ui-preference',key=key,value=value}))
end
local function audio_filters()
  local filters={}
  if state.vocal then filters[#filters+1]='lavfi=[highpass=f=80,equalizer=f=1000:t=q:w=1.5:g=6,equalizer=f=2800:t=q:w=1.5:g=4]' end
  if state.night then filters[#filters+1]='lavfi=[dynaudnorm=f=200:g=15:p=0.85]' end
  return table.concat(filters,',')
end
local function panel_rows(mode)
  local heading,rows
  if mode=='resources' then heading='资源版本'; rows={}; for i,item in ipairs(resources()) do local detail=item.details or {}; local info={}; if detail.height then info[#info+1]=(tonumber(detail.height)>=2000 and '4K' or tostring(detail.height)..'P') end; if detail.codec and detail.codec~='' then info[#info+1]=tostring(detail.codec):upper() end; if tonumber(detail.bitrate)>0 then info[#info+1]=string.format('%.1f Mbps',tonumber(detail.bitrate)/1000000) end; local active=item.url==mp.get_property('path',''); rows[#rows+1]={kind='resource',index=i,title=item.label or ('资源 '..i),detail=active and '正在播放' or table.concat(info,' · '),active=active} end
  elseif mode=='audio' then heading='声音'; rows={}; for _,track in ipairs(tracks('audio')) do rows[#rows+1]={kind='audio',id=track.id,preference=track_signature(track),title=track.title or track.lang or ('音轨 '..track.id),detail=track_detail(track),active=track.selected} end; rows[#rows+1]={kind='downmix',icon='audio',title='立体声下混',detail=state.downmix and '已开启' or '关闭',active=state.downmix}; rows[#rows+1]={kind='vocal',icon='audio',title='人声增强',detail=state.vocal and '已开启' or '关闭',active=state.vocal}; rows[#rows+1]={kind='night',icon='audio',title='夜间模式',detail=state.night and '已开启' or '关闭',active=state.night}; rows[#rows+1]={kind='audio-delay',icon='audio',title='音频延迟',detail=string.format('%+.0f ms',(tonumber(mp.get_property_native('audio-delay')) or 0)*1000)}
  elseif mode=='subtitle' then heading='字幕'; rows={{kind='subtitle-off',title='关闭字幕',detail='',active=mp.get_property('sid','no')=='no'}}; for _,track in ipairs(tracks('sub')) do rows[#rows+1]={kind='subtitle',id=track.id,preference=track_signature(track),title=track.title or track.lang or ('字幕 '..track.id),detail=track_detail(track),active=track.selected} end; rows[#rows+1]={kind='subtitle-scale',icon='subtitle',title='字幕大小',detail=string.format('%.0f%%',(tonumber(mp.get_property_native('sub-scale')) or 1)*100)}; rows[#rows+1]={kind='subtitle-pos',icon='layout',title='垂直位置',detail=string.format('底部 %.0f%%',100-(tonumber(mp.get_property_native('sub-pos')) or 92))}; rows[#rows+1]={kind='subtitle-delay',icon='speed',title='字幕延迟',detail=string.format('%+.1f 秒',tonumber(mp.get_property_native('sub-delay')) or 0)}; rows[#rows+1]={kind='subtitle-border',icon='subtitle',title='文字描边',detail=string.format('%.1f px',tonumber(mp.get_property_native('sub-border-size')) or 1.5)}
  elseif mode=='speed' then heading='播放速度'; rows={}; for _,value in ipairs({.5,.75,1,1.25,1.5,1.75,2}) do local active=math.abs((mp.get_property_native('speed') or 1)-value)<.01; rows[#rows+1]={kind='speed',value=value,title=string.format('%.2g 倍',value),detail=active and '当前速度' or '',active=active} end
  elseif mode=='chapters' then heading='片头 · 片尾'; local rule=state.chapterRule or {}; rows={{kind='chapter-set-intro',title='将当前时间设为片头结束',detail=rule.introEnd and fmt(rule.introEnd) or '未设置'},{kind='chapter-set-outro',title='将当前时间设为片尾开始',detail=rule.outroStart and fmt(rule.outroStart) or '未设置'},{kind='chapter-auto',title='自动跳过',detail=state.chapterAutoSkip and '已开启' or '已关闭',active=state.chapterAutoSkip}}; if rule.source then rows[#rows+1]={kind='info',title='规则来源',detail=tostring(rule.source)} end; for i,item in ipairs(mp.get_property_native('chapter-list') or {}) do rows[#rows+1]={kind='chapter',index=i-1,title=item.title or ('媒体章节 '..i),detail=fmt(item.time)} end; rows[#rows+1]={kind='chapter-clear',title='删除本集规则',detail=''}
  elseif mode=='danmaku' then heading='弹幕'; local track=danmaku_track(); local active=track and tostring(mp.get_property('secondary-sid','no'))==tostring(track.id); local mode_label=state.danmakuMode=='top' and '顶部优先' or state.danmakuMode=='bottom' and '底部优先' or '智能避让'; rows={{kind='info',icon='info',title='弹幕匹配集',detail='第 '..tostring(state.season or '?')..' 季 · 第 '..tostring(state.episode or '?')..' 集'},{kind='info',icon='count',title='当前状态',detail=(state.danmakuCount or 0)>0 and (tostring(state.danmakuCount)..' 条待播放') or '正在等待来源'},{kind='danmaku-toggle',icon='eye',title='显示弹幕',detail=active and '开启' or '关闭',active=active},{kind='danmaku-density',icon='density',title='显示密度',detail=state.danmakuDensity=='high' and '密集' or state.danmakuDensity=='low' and '稀疏' or '标准'},{kind='danmaku-mode',icon='layout',title='显示模式',detail=mode_label},{kind='danmaku-font',icon='info',title='字号',detail=tostring(state.danmakuFontScale or 100)..'%'},{kind='danmaku-opacity',icon='eye',title='不透明度',detail=tostring(state.danmakuOpacity or 86)..'%'},{kind='danmaku-duration',icon='speed',title='停留时间',detail=tostring(state.danmakuDuration or 5)..' 秒'},{kind='danmaku-count',icon='count',title='最大数量',detail=tostring(state.danmakuMaxCount or 1500)..' 条'},{kind='danmaku-outline',icon='subtitle',title='文字描边',detail=state.danmakuOutline=='strong' and '增强' or state.danmakuOutline=='none' and '关闭' or '柔和'},{kind='danmaku-reload',icon='refresh',title='重新获取弹幕',detail='重新查询所有来源'}}; for _,source in ipairs(state.danmakuSourceInfo or {}) do rows[#rows+1]={kind='info',icon='source',title=tostring(source.name or '弹幕 API'),detail=tostring(source.status or '')} end
  elseif mode=='playback' then heading='播放'; local looping=mp.get_property('loop-file','no')=='inf'; local ontop=mp.get_property_native('ontop',false); rows={{kind='speed',value=.5,title='0.5 倍',detail='慢速',active=math.abs((mp.get_property_native('speed') or 1)-.5)<.01},{kind='speed',value=.75,title='0.75 倍',detail='慢速',active=math.abs((mp.get_property_native('speed') or 1)-.75)<.01},{kind='speed',value=1,title='1.0 倍',detail='标准',active=math.abs((mp.get_property_native('speed') or 1)-1)<.01},{kind='speed',value=1.25,title='1.25 倍',detail='快速',active=math.abs((mp.get_property_native('speed') or 1)-1.25)<.01},{kind='speed',value=1.5,title='1.5 倍',detail='快速',active=math.abs((mp.get_property_native('speed') or 1)-1.5)<.01},{kind='loop-file',icon='loop',title='单集循环',detail=looping and '开启' or '关闭',active=looping},{kind='ab-loop',icon='loop',title='A-B 循环',detail='设置片段起止点'},{kind='capture',icon='capture',title='截取画面',detail='包含当前字幕'},{kind='ontop',icon='pin',title='窗口置顶',detail=ontop and '开启' or '关闭',active=ontop}}
  elseif mode=='picture' then heading='画面'; local aspect=mp.get_property('video-aspect-override','no'); rows={{kind='aspect',icon='picture',title='画面比例',detail=aspect=='no' and '原始比例' or aspect},{kind='zoom',icon='picture',title='缩放',detail=string.format('%.0f%%',(tonumber(mp.get_property_native('video-zoom')) or 0)*100)},{kind='rotate',icon='picture',title='旋转',detail=tostring(mp.get_property_native('video-rotate') or 0)..'°'},{kind='picture-reset',icon='refresh',title='恢复画面默认',detail='比例、缩放与旋转'},{kind='hardware',icon='picture',title='硬件解码',detail=state.hardware and '已开启 · 下次播放生效' or '软解 · 下次播放生效',active=state.hardware},{kind='hwdec-mode',icon='picture',title='硬解模式',detail=tostring(state.hwdec or 'auto-safe')..' · 下次播放生效'},{kind='renderer',icon='picture',title='渲染器',detail=tostring(state.renderer or 'gpu-next')..' · 下次播放生效'},{kind='gpu',icon='picture',title='GPU 选择',detail=(state.gpu and state.gpu~='' and state.gpu or '自动')..' · 下次播放生效'},{kind='hdr',icon='picture',title='HDR 与 Dolby Vision',detail=state.hdr and '跟随显示器 · 下次播放生效' or '已关闭 · 下次播放生效',active=state.hdr},{kind='info',icon='info',title='实际硬解',detail=mp.get_property('hwdec-current','自动')},{kind='info',icon='info',title='视频输出',detail=mp.get_property('current-vo','--')}}
  elseif mode=='info' then heading='播放信息'; local video=mp.get_property_native('video-params') or {}; local audio=mp.get_property_native('audio-params') or {}; rows={{kind='info',icon='resources',title='播放路径',detail=state.resourceLabel or '当前资源'},{kind='info',icon='info',title='网络缓存',detail=rate(mp.get_property_native('cache-speed'))},{kind='info',icon='picture',title='视频',detail=tostring(video.pixelformat or mp.get_property('video-format','--')):upper()..' · '..tostring(video.w or '--')..'×'..tostring(video.h or '--')},{kind='info',icon='audio',title='音频',detail=tostring(audio.format or mp.get_property('audio-format','--')):upper()..' · '..tostring(audio['channel-count'] or '--')..' 声道'},{kind='info',icon='speed',title='帧率',detail=string.format('%.3f FPS',tonumber(mp.get_property_native('estimated-vf-fps')) or 0)},{kind='info',icon='info',title='丢帧',detail=tostring(mp.get_property_native('vo-drop-frame-count') or 0)}}
  else heading=''; rows={} end
  if #rows==0 then rows[1]={kind='info',title='暂无可用项目',detail=''} end
  return heading,rows
end
local function row_actionable(row) return row and row.kind and row.kind~='info' end
local function first_panel_row(mode)
  local _,rows=panel_rows(mode)
  for index,row in ipairs(rows) do if row_actionable(row) then return index end end
  return 1
end
local function move_to_actionable(rows,current,delta)
  local candidate=current
  for _=1,#rows do
    local next_index=clamp(candidate+delta,1,#rows)
    if next_index==candidate then return candidate end
    candidate=next_index
    if row_actionable(rows[candidate]) then return candidate end
  end
  return current
end

local function clear_overlays()
  if #overlay_ids==0 then return end
  for _,id in ipairs(overlay_ids) do safe_overlay_command('overlay-remove',id) end
  overlay_ids={}; overlay_signature=''
end
local function sync_logo_overlay()
  local logo=state.seriesLogoImage; if not logo or not logo.file then if logo_overlay_signature~='' then safe_overlay_command('overlay-remove',10); logo_overlay_signature='' end; return end
  local signature=table.concat({logo.file,logo.width,logo.height},':'); if signature==logo_overlay_signature then return end
  safe_overlay_command('overlay-remove',10)
  if safe_overlay_command('overlay-add',10,40,17,logo.file,0,'bgra',logo.width,logo.height,logo.stride) then logo_overlay_signature=signature end
end
local function sync_episode_overlays(cards)
  local parts={}
  for _,card in ipairs(cards) do local thumb=card.item.thumbnail; if thumb and thumb.file then parts[#parts+1]=table.concat({thumb.file,math.floor(card.image_x),math.floor(card.image_y)},':') end end
  local signature=table.concat(parts,'|'); if signature==overlay_signature then return end
  clear_overlays(); overlay_signature=signature
  for index,card in ipairs(cards) do local thumb=card.item.thumbnail; if thumb and thumb.file then local id=20+index; if safe_overlay_command('overlay-add',id,math.floor(card.image_x),math.floor(card.image_y),thumb.file,0,'bgra',thumb.width,thumb.height,thumb.stride) then overlay_ids[#overlay_ids+1]=id end end end
end
local function current_episode_index()
  for index,item in ipairs(episodes()) do if tonumber(item.season)==tonumber(state.season) and tonumber(item.episode)==tonumber(state.episode) then return index end end
  return 1
end
local function episode_cards(w,l)
  local list=episodes(); local tray={x=l.edge+34,y=l.console_y-236,w=w-(l.edge+34)*2,h=214}; local count=math.min(5,#list,math.max(1,math.floor((tray.w-26)/286))); if #list==0 then return {},tray end
  local start=clamp(panel_offset>0 and panel_offset or current_episode_index()-2,1,math.max(1,#list-count+1)); panel_offset=start
  local gap,padding=14,20; local card_w=(tray.w-padding*2-gap*(count-1))/count; local cards={}
  for slot=1,count do local item=list[start+slot-1]; local x=tray.x+padding+(slot-1)*(card_w+gap); cards[#cards+1]={item=item,index=start+slot-1,x=x,y=tray.y+48,w=card_w,h=142,image_x=x+(card_w-272)/2,image_y=tray.y+54} end
  return cards,tray
end

local function set_active_context(item) local ok,json=pcall(utils.format_json,item); if ok and json then mp.set_property('user-data/yj-active',json) end end
local function load_item(item,is_episode)
  if not item or not item.url then return end
  pending_seek=is_episode and 0 or (tonumber((mp.get_property_native('time-pos'))) or 0)
  if item.token and item.token~='' then mp.set_property('http-header-fields','X-Emby-Token: '..item.token) end
  if is_episode then state.season=item.season; state.episode=item.episode; state.episodeName=item.episodeName; state.seriesLogo=item.seriesLogo or state.seriesLogo; state.resourceOptions=type(item.resourceOptions)=='table' and item.resourceOptions or {item}; state.resourceLabel=state.resourceOptions[1] and state.resourceOptions[1].label or item.label; state.resourceDetails=state.resourceOptions[1] and state.resourceOptions[1].details or item.details or {}; state.chapterKey=item.chapterKey or ''; state.chapterRule=item.chapterRule; state.danmakuContext=item.danmakuContext or state.danmakuContext; local old=danmaku_track(); if old then mp.commandv('sub-remove',tostring(old.id)) end; state.danmakuCount=0; state.danmakuSourceInfo={{name='弹幕',status='正在匹配新剧集'}}; mp.set_property('user-data/yj-player-action',utils.format_json({type='episode-change',preferenceKey=state.playerPreferenceKey,context=state.danmakuContext or {season=item.season,episode=item.episode,title=item.seriesLogo}}))
  else state.resourceLabel=item.label or state.resourceLabel; state.resourceDetails=item.details or {} end
  set_active_context(item); clear_overlays(); mp.commandv('loadfile',item.url,'replace'); panel_mode=nil; panel_offset=0; if set_panel_key_bindings then set_panel_key_bindings(false) end; show(4.5)
end
local function step_episode(delta)
  local list=episodes(); if #list==0 then mp.commandv(delta<0 and 'playlist-prev' or 'playlist-next','force'); return end
  local current=current_episode_index(); local index=clamp(current+delta,1,#list); if index~=current then load_item(list[index],true) end
end
local function run_row(row)
  if not row or row.kind=='info' then return end
  if row.kind=='resource' then load_item(resources()[row.index],false)
  elseif row.kind=='audio' then mp.set_property('aid',tostring(row.id)); save_media_preference('audioTrack',row.preference); panel_mode=nil
  elseif row.kind=='subtitle' then mp.set_property('sid',tostring(row.id)); mp.set_property('sub-visibility','yes'); save_media_preference('subtitleTrack',row.preference); panel_mode=nil
  elseif row.kind=='subtitle-off' then mp.set_property('sid','no'); save_media_preference('subtitleTrack','off'); panel_mode=nil
  elseif row.kind=='speed' then mp.set_property_native('speed',row.value); save_media_preference('speed',row.value); panel_mode=nil
  elseif row.kind=='audio-delay' then cycle_property('audio-delay',{-1,-.5,0,.5,1},'audioDelay')
  elseif row.kind=='downmix' then state.downmix=not state.downmix; mp.set_property('audio-channels',state.downmix and 'stereo' or 'auto'); save_ui_preference('downmix',state.downmix)
  elseif row.kind=='vocal' then state.vocal=not state.vocal; mp.set_property('af',audio_filters()); save_ui_preference('vocal',state.vocal)
  elseif row.kind=='night' then state.night=not state.night; mp.set_property('af',audio_filters()); save_ui_preference('night',state.night)
  elseif row.kind=='subtitle-scale' then cycle_property('sub-scale',{.85,1,1.15,1.3},'subtitleScale')
  elseif row.kind=='subtitle-pos' then cycle_property('sub-pos',{86,90,92,94},'subtitlePos')
  elseif row.kind=='subtitle-delay' then cycle_property('sub-delay',{-1,-.5,0,.5,1},'subtitleDelay')
  elseif row.kind=='subtitle-border' then cycle_property('sub-border-size',{0,1.5,2.4},'subtitleBorder')
  elseif row.kind=='chapter' then mp.set_property_native('chapter',row.index); panel_mode=nil
  elseif row.kind=='danmaku-toggle' then local track=danmaku_track(); state.danmakuEnabled=not state.danmakuEnabled; if track then mp.set_property('secondary-sid',state.danmakuEnabled and tostring(track.id) or 'no') end; save_media_preference('danmakuEnabled',state.danmakuEnabled,state.danmakuEnabled and not track)
  elseif row.kind=='danmaku-reload' then local old=danmaku_track(); if old then mp.commandv('sub-remove',tostring(old.id)) end; state.danmakuCount=0; state.danmakuSourceInfo={{name='弹幕',status='正在重新获取'}}; mp.set_property('user-data/yj-player-action',utils.format_json({type='episode-change',preferenceKey=state.playerPreferenceKey,context=state.danmakuContext or {season=state.season,episode=state.episode,title=state.seriesLogo}}))
  elseif row.kind=='danmaku-density' then state.danmakuDensity=state.danmakuDensity=='low' and 'normal' or state.danmakuDensity=='normal' and 'high' or 'low'; save_media_preference('danmakuDensity',state.danmakuDensity,true)
  elseif row.kind=='danmaku-mode' then state.danmakuMode=state.danmakuMode=='smart' and 'top' or state.danmakuMode=='top' and 'bottom' or 'smart'; save_media_preference('danmakuMode',state.danmakuMode,true)
  elseif row.kind=='danmaku-font' then local values={80,100,120,140}; local current=tonumber(state.danmakuFontScale) or 100; local index=1; for i,value in ipairs(values) do if value==current then index=i end end; state.danmakuFontScale=values[index%#values+1]; save_media_preference('danmakuFontScale',state.danmakuFontScale,true)
  elseif row.kind=='danmaku-opacity' then local values={70,86,100}; local current=tonumber(state.danmakuOpacity) or 86; local index=1; for i,value in ipairs(values) do if value==current then index=i end end; state.danmakuOpacity=values[index%#values+1]; save_media_preference('danmakuOpacity',state.danmakuOpacity,true)
  elseif row.kind=='danmaku-duration' then local values={4,5,6,8}; local current=tonumber(state.danmakuDuration) or 5; local index=1; for i,value in ipairs(values) do if value==current then index=i end end; state.danmakuDuration=values[index%#values+1]; save_media_preference('danmakuDuration',state.danmakuDuration,true)
  elseif row.kind=='danmaku-count' then local values={800,1500,3000}; local current=tonumber(state.danmakuMaxCount) or 1500; local index=1; for i,value in ipairs(values) do if value==current then index=i end end; state.danmakuMaxCount=values[index%#values+1]; save_media_preference('danmakuMaxCount',state.danmakuMaxCount,true)
  elseif row.kind=='danmaku-outline' then state.danmakuOutline=state.danmakuOutline=='none' and 'soft' or state.danmakuOutline=='soft' and 'strong' or 'none'; save_media_preference('danmakuOutline',state.danmakuOutline,true)
  elseif row.kind=='chapter-auto' then state.chapterAutoSkip=not state.chapterAutoSkip; save_media_preference('chapterAutoSkip',state.chapterAutoSkip)
  elseif row.kind=='loop-file' then local enabled=mp.get_property('loop-file','no')~='inf'; mp.set_property('loop-file',enabled and 'inf' or 'no'); save_media_preference('loopFile',enabled)
  elseif row.kind=='ab-loop' then mp.commandv('ab-loop')
  elseif row.kind=='capture' then mp.commandv('screenshot')
  elseif row.kind=='ontop' then mp.commandv('cycle','ontop')
  elseif row.kind=='aspect' then local values={'no','16:9','4:3','2.35:1'}; local current=mp.get_property('video-aspect-override','no'); local index=1; for i,value in ipairs(values) do if value==current then index=i end end; local next_value=values[index%#values+1]; mp.set_property('video-aspect-override',next_value); state.videoAspect=next_value=='no' and 'auto' or next_value; save_media_preference('videoAspect',state.videoAspect)
  elseif row.kind=='zoom' then cycle_property('video-zoom',{0,.15,.3},'videoZoom')
  elseif row.kind=='rotate' then cycle_property('video-rotate',{0,90,180,270},'videoRotate')
  elseif row.kind=='picture-reset' then mp.set_property('video-aspect-override','no'); mp.set_property_native('video-zoom',0); mp.set_property_native('video-rotate',0); state.videoAspect='auto'; state.videoZoom=0; state.videoRotate=0; save_media_preference('videoAspect','auto'); save_media_preference('videoZoom',0); save_media_preference('videoRotate',0)
  elseif row.kind=='hardware' then state.hardware=not state.hardware; save_ui_preference('hardware',state.hardware)
  elseif row.kind=='hdr' then state.hdr=not state.hdr; save_ui_preference('hdr',state.hdr)
  elseif row.kind=='hwdec-mode' then local values={'auto-safe','d3d11va','d3d11va-copy','no'}; local index=1; for i,value in ipairs(values) do if value==state.hwdec then index=i end end; state.hwdec=values[index%#values+1]; save_ui_preference('hwdec',state.hwdec)
  elseif row.kind=='renderer' then state.renderer=state.renderer=='gpu-next' and 'gpu' or 'gpu-next'; save_ui_preference('renderer',state.renderer)
  elseif row.kind=='gpu' then local values={''}; for _,value in ipairs(state.gpuAdapters or {}) do values[#values+1]=value end; local index=1; for i,value in ipairs(values) do if value==state.gpu then index=i end end; state.gpu=values[index%#values+1]; save_ui_preference('gpu',state.gpu)
  elseif row.kind=='chapter-set-intro' or row.kind=='chapter-set-outro' then local field=row.kind=='chapter-set-intro' and 'introEnd' or 'outroStart'; local value=tonumber((mp.get_property_native('time-pos'))) or 0; state.chapterRule=state.chapterRule or {source='手动'}; state.chapterRule[field]=value; state.chapterRule.source='手动'; for _,episode in ipairs(episodes()) do if episode.chapterKey==state.chapterKey then episode.chapterRule=state.chapterRule end end; mp.set_property('user-data/yj-player-action',utils.format_json({type='chapter-rule',key=state.chapterKey,field=field,time=value}))
  elseif row.kind=='chapter-clear' then state.chapterRule=nil; for _,episode in ipairs(episodes()) do if episode.chapterKey==state.chapterKey then episode.chapterRule=nil end end; mp.set_property('user-data/yj-player-action',utils.format_json({type='chapter-rule',key=state.chapterKey,field='clear'})) end
  if not panel_mode and set_panel_key_bindings then set_panel_key_bindings(false) end
  show(panel_mode and 12 or 4.2)
end

local function draw_top(ass,w,l)
  local logo=state.seriesLogoImage; local copy_x=l.edge+12
  if not (logo and logo.file) then text(ass,copy_x,43,25,7,state.seriesLogo or '映迹','FFFFFF',0,true); copy_x=copy_x+math.min(240,#tostring(state.seriesLogo or '')*24+34) else copy_x=40+logo.width+28 end
  local episode_label='第 '..tostring(state.season or '?')..' 季  ·  第 '..tostring(state.episode or '?')..' 集'
  local episode_name=tostring(state.episodeName or '')
  if episode_name~='' then episode_label=episode_label..'  ·  '..episode_name end
  clipped_text(ass,copy_x,48,17,7,episode_label,'FFFFFF',0,true,copy_x,24,w-l.edge-242,72)
  text(ass,w-l.edge-205,35,13,9,rate(mp.get_property_native('cache-speed')),'E6DED9',0,true)
  local top_labels={pin='置顶',min='最小化',max='最大化',close='关闭'}
  for _,button in ipairs(top_buttons(w,l)) do local selected=button.name=='pin' and mp.get_property_native('ontop',false); local hovered=hit(mouse_x,mouse_y,button.x-18,17,button.x+18,53); control_halo(ass,button.x,35,hovered,selected,16); icon(ass,button.x,35,button.name,selected and 'FFFFFF' or (hovered and 'FFFFFF' or 'E6DED9'),.82); if hovered then tooltip(ass,button.x,70,top_labels[button.name]) end end
end
local function draw_console(ass,w,l)
  local duration=tonumber((mp.get_property_native('duration'))) or 0; local position=tonumber((mp.get_property_native('time-pos'))) or 0; local progress=duration>0 and clamp(position/duration,0,1) or 0
  text(ass,l.console_x+30,l.progress_y+4,13,4,fmt(position),'F7F8FC',0,true); text(ass,l.console_x+l.console_w-30,l.progress_y+4,13,6,fmt(duration),'F7F8FC',0,true)
  local track_x=l.console_x+86; local track_w=l.console_w-172; rect(ass,track_x,l.progress_y-3,track_w,3,'96897F',76); rect(ass,track_x,l.progress_y-3,math.max(2,track_w*progress),3,'FFFFFF',0); circle(ass,track_x+track_w*progress,l.progress_y-1,6,'FFFFFF',0)
  local video=mp.get_property_native('video-params') or {}; local detail=state.resourceDetails or {}
  local height=tonumber(detail.height) or tonumber(video.h) or 0; local quality=height>=2000 and '4K' or height>=1000 and '1080P' or height>0 and tostring(height)..'P' or 'HD'
  local codec=tostring(detail.codec or ''):upper(); if codec=='' then codec=mp.get_property('video-format',''):upper() end
  local fps=tonumber(detail.fps) or tonumber((mp.get_property_native('estimated-vf-fps'))) or 0
  local range=tostring(detail.range or ''):upper(); local hdr=range~='' and range or (video.gamma=='pq' and 'HDR10' or video.gamma=='hlg' and 'HLG' or 'SDR')
  local bitrate=tonumber(detail.bitrate) or tonumber((mp.get_property_native('bitrate'))) or 0
  local container=tostring(detail.container or ''):upper()
  local specs={quality,codec~='' and codec or 'VIDEO',hdr,fps>0 and string.format('%.2g FPS',fps) or 'FPS --'}; if bitrate>0 then specs[#specs+1]=string.format('%.1f Mbps',bitrate/1000000) end; if container~='' then specs[#specs+1]=container end
  local spec_copy=table.concat(specs,'  ·  ')
  clipped_text(ass,l.console_x+30,l.meta_y,12,7,spec_copy,'DCE1E8',0,true,l.console_x+30,l.meta_y-18,w*.43,l.meta_y+12)
  local paused=mp.get_property_native('pause',false)
  local transport_labels={prev='上一集',back='快退 10 秒',pause=paused and '播放' or '暂停',forward='快进 10 秒',next='下一集'}
  for _,button in ipairs(transport_buttons(w,l)) do local hovered=hit(mouse_x,mouse_y,button.x-24,l.center_y-24,button.x+24,l.center_y+24); control_halo(ass,button.x,l.center_y,hovered,false,button.name=='pause' and 21 or 18); if hovered then tooltip(ass,button.x,l.center_y-31,transport_labels[button.name]) end; icon(ass,button.x,l.center_y,button.name=='pause' and (paused and 'play' or 'pause') or button.name,hovered and 'FFFFFF' or 'D8DEE7',button.name=='pause' and 1.1 or .88) end
  local volume=upper_controls(w,l)
  local volume_hover=hit(mouse_x,mouse_y,volume.x,volume.y,volume.x+volume.w,volume.y+volume.h); control_halo(ass,volume.x+12,volume.y+17,volume_hover,false,14); icon(ass,volume.x+12,volume.y+17,'volume','F7F8FC',.65); local value=clamp((tonumber((mp.get_property_native('volume'))) or 100)/100,0,1); rect(ass,volume.x+30,volume.y+16,volume.w-40,3,'8B939F',98); rect(ass,volume.x+30,volume.y+16,(volume.w-40)*value,3,'FFFFFF',0); circle(ass,volume.x+30+(volume.w-40)*value,volume.y+17.5,5,'FFFFFF',0); if volume_hover then tooltip(ass,volume.x+volume.w/2,volume.y,'音量') end
  for _,button in ipairs(utility_buttons(w,l)) do
    local selected=(button.name=='subtitle' and panel_mode=='subtitle') or (button.name=='danmaku' and panel_mode=='danmaku') or (button.name=='settings' and panel_mode and panel_mode~='episodes' and panel_mode~='subtitle' and panel_mode~='danmaku')
    local hovered=hit(mouse_x,mouse_y,button.x,button.y,button.x+button.w,button.y+button.h); local color=selected and 'FFFFFF' or (hovered and 'FFFFFF' or 'D8DEE7')
    control_halo(ass,button.x+button.w/2,button.y+18,hovered,selected,16); icon(ass,button.x+button.w/2,button.y+18,button.name,color,.66); if hovered then tooltip(ass,button.x+button.w/2,button.y,utility_labels[button.name]) end
  end
end

local function panel_anchor(w,l,name)
  for _,button in ipairs(utility_buttons(w,l)) do if button.name==name then return button.x+button.w/2 end end
  return w-l.edge-220
end
local function panel_motion()
  local t=clamp((now()-panel_opened_at)/.22,0,1)
  return 1-(1-t)*(1-t)*(1-t)
end
local kind_icons={info='info',audio='audio',subtitle='subtitle',resource='resources',speed='speed',chapter='chapters',['subtitle-off']='eye',['danmaku-toggle']='eye',['danmaku-density']='density',['danmaku-mode']='layout',['danmaku-font']='info',['danmaku-opacity']='eye',['danmaku-duration']='speed',['danmaku-count']='count',['danmaku-outline']='subtitle',['danmaku-reload']='refresh',['chapter-auto']='refresh',['chapter-set-intro']='chapters',['chapter-set-outro']='chapters',['chapter-clear']='close',['audio-delay']='audio',downmix='audio',vocal='audio',night='audio',['subtitle-scale']='subtitle',['subtitle-pos']='layout',['subtitle-delay']='speed',['subtitle-border']='subtitle',['loop-file']='loop',['ab-loop']='loop',capture='capture',ontop='pin',aspect='picture',zoom='picture',rotate='picture',['picture-reset']='refresh',hardware='picture',['hwdec-mode']='picture',renderer='picture',gpu='picture',hdr='picture'}
local function settings_panel_geometry(w,l)
  local _,h=dimensions(); local _,rows=panel_rows(panel_mode); local body_y=154; local count=math.max(1,math.floor((h-body_y-22)/56))
  return {x=l.rail_x,y=0,w=l.rail_w,h=h,body_y=body_y,count=math.min(count,#rows),rows=rows}
end
local function draw_list_panel(ass,w,l)
  clear_overlays()
  local heading=select(1,panel_rows(panel_mode)); local box=settings_panel_geometry(w,l); panel_offset=clamp(panel_offset,0,math.max(0,#box.rows-box.count))
  rect(ass,box.x,box.y,box.w,box.h,'08090D',10); rect(ass,box.x,box.y,1,box.h,'FFFFFF',220)
  text(ass,box.x+22,30,17,7,'播放设置','FFFFFF',0,true); text(ass,box.x+22,51,11,7,'改动即时下发给 mpv，并记入播放偏好。','AAB2BE',0,false)
  local tab_x=box.x+16; local tab_w=(box.w-32)/#settings_sections
  for index,item in ipairs(settings_sections) do
    local tx=tab_x+(index-1)*tab_w; local selected=item.mode==panel_mode; local focused=panel_nav_focus and index==panel_section_focus; local hovered=hit(mouse_x,mouse_y,tx,73,tx+tab_w,109)
    row_surface(ass,tx+2,76,tab_w-4,30,8,selected,focused,hovered); local color=(selected or focused) and 'FFFFFF' or 'B8C0CC'
    text(ass,tx+tab_w/2,96,11,5,item.label,color,0,true)
  end
  rect(ass,box.x+20,120,box.w-40,1,'FFFFFF',232)
  local detail_x=box.x+18; icon(ass,detail_x+10,139,settings_sections[settings_section_index(panel_mode)].icon,'FFFFFF',.5); text(ass,detail_x+30,144,16,7,heading,'FFFFFF',0,true); text(ass,box.x+box.w-22,143,11,9,tostring(#box.rows)..' 项','B8C0CC',0,true)
  for index=1,box.count do
    local absolute=panel_offset+index; local row=box.rows[absolute]; local ry=box.body_y+(index-1)*56; local active=row.active==true; local focused=not panel_nav_focus and absolute==panel_focus; local hovered=hit(mouse_x,mouse_y,detail_x,ry,box.x+box.w-14,ry+48)
    row_surface(ass,detail_x,ry,box.w-36,48,14,active,focused,hovered); local row_color=(active or focused) and 'FFFFFF' or 'D8DEE7'; local detail_color=(active or focused) and 'E8EFF8' or 'AEB8C5'
    icon(ass,detail_x+24,ry+24,row.icon or kind_icons[row.kind] or 'info',row_color,.56); local detail_right=active and box.x+box.w-58 or box.x+box.w-24
    clipped_text(ass,detail_x+48,ry+22,13,7,row.title,row_color,0,true,detail_x+46,ry+6,box.x+box.w-170,ry+42); clipped_text(ass,detail_right,ry+22,10,9,row.detail or '',detail_color,0,false,box.x+box.w-164,ry+6,detail_right,ry+42)
    local switches={downmix=true,vocal=true,night=true,['danmaku-toggle']=true,['chapter-auto']=true,['loop-file']=true,ontop=true,hardware=true,hdr=true}
    if switches[row.kind] then
      local sx,sy=box.x+box.w-58,ry+12; roundrect(ass,sx,sy,36,24,12,active and '6FBD76' or 'FFFFFF',active and 0 or 210); circle(ass,sx+(active and 24 or 12),sy+12,9,active and 'FFFFFF' or '262A33',0)
    elseif active then icon(ass,box.x+box.w-42,ry+24,'check','FFFFFF',.44) end
  end
end
local function draw_episode_panel(ass,w,l)
  local cards,tray=episode_cards(w,l); local lift=(1-panel_motion())*12; tray.y=tray.y+lift; for _,card in ipairs(cards) do card.y=card.y+lift; card.image_y=card.image_y+lift end; glass(ass,tray.x,tray.y,tray.w,tray.h,20)
  icon(ass,tray.x+30,tray.y+29,'episodes','FFFFFF',.58); text(ass,tray.x+50,tray.y+33,17,7,'选集','FFFFFF',0,true); text(ass,tray.x+tray.w-22,tray.y+32,11,9,tostring(#episodes())..' 集','B8C0CC',0,true); rect(ass,tray.x+20,tray.y+40,tray.w-40,1,'FFFFFF',230)
  if #cards==0 then clear_overlays(); text(ass,tray.x+tray.w/2,tray.y+122,16,5,'暂无可切换剧集','B8C0CC',0,true); return end
  pending_overlay_cards=cards
  for _,card in ipairs(cards) do
    local active=tonumber(card.item.season)==tonumber(state.season) and tonumber(card.item.episode)==tonumber(state.episode); local hovered=hit(mouse_x,mouse_y,card.x,card.y,card.x+card.w,card.y+card.h)
    if not card.item.thumbnail then roundrect(ass,card.x,card.y,card.w,106,12,'34281E',86) end
    roundrect(ass,card.x,card.y+106,card.w,36,0,'100B08',70)
    if active then roundrect(ass,card.x-2,card.y-2,card.w+4,card.h+4,14,'FFFFFF',168); roundrect(ass,card.x,card.y,card.w,card.h,12,'1A1410',188)
    elseif card.index==panel_focus then roundrect(ass,card.x-2,card.y-2,card.w+4,card.h+4,14,'FFFFFF',202)
    elseif hovered then roundrect(ass,card.x,card.y,card.w,card.h,12,'FFFFFF',232) end
    text(ass,card.x+12,card.y+130,13,7,'E'..tostring(card.item.episode or card.index),'FFFFFF',0,true); clipped_text(ass,card.x+48,card.y+130,12,7,tostring(card.item.episodeName or card.item.label or ''),'E2E7EE',0,true,card.x+48,card.y+111,card.x+card.w-14,card.y+140)
    if active then icon(ass,card.x+card.w-18,card.y+124,'check','FFFFFF',.38) end
  end
end

function render()
  local w,h=dimensions(); if not w or w<=0 or not visible() then clear_overlays(); if logo_overlay_signature~='' then safe_overlay_command('overlay-remove',10); logo_overlay_signature='' end; mp.set_osd_ass(0,0,''); return end
  if not render_logged then mp.msg.info(string.format('[yingji_osc] render active (%dx%d)',w,h)); render_logged=true end
  pending_overlay_cards=nil; local ass=assdraw.ass_new(); local l=layout(w,h); draw_top(ass,w,l); draw_console(ass,w,l)
  if panel_mode=='episodes' then draw_episode_panel(ass,w,l) else draw_list_panel(ass,w,l) end
  mp.set_osd_ass(w,h,ass.text)
  sync_logo_overlay()
  if pending_overlay_cards then sync_episode_overlays(pending_overlay_cards) end
end

-- Keep a malformed optional panel from taking down the entire playback console.
-- mpv reports the exception and the next timer tick can recover on its own.
local render_impl = render
local render_error_reported = false
local function render_fallback(error_text)
  local w,h=dimensions(); if not w or not h or w<=0 or h<=0 then return end
  local ass=assdraw.ass_new(); local edge=math.max(24,math.floor(w*.018)); local y=h-edge-84
  roundrect(ass,edge,y,w-edge*2,64,16,'10151D',30); roundrect(ass,edge,y,w-edge*2,64,16,'FFFFFF',185)
  text(ass,edge+22,y+26,16,7,state.seriesLogo or '映迹','FFFFFF',0,true)
  text(ass,edge+22,y+48,12,7,'播放控件正在恢复… '..tostring(error_text or ''),'C9BEB5',0,false)
  text(ass,w-edge-22,y+37,12,9,'空格 播放/暂停 · ←/→ 快退快进','EDE7E2',0,true)
  mp.set_osd_ass(w,h,ass.text)
end
function render()
  if headless then
    clear_overlays()
    mp.set_osd_ass(0,0,'')
    return
  end
  local ok, err = pcall(render_impl)
  if not ok and not render_error_reported then
    render_error_reported = true
    mp.msg.error('[yingji_osc] render failed: '..tostring(err))
    render_fallback(tostring(err))
  end
end

local move_panel_focus,activate_panel_focus
move_panel_focus=function(delta)
  if not panel_mode then return false end
  local total=panel_mode=='episodes' and #episodes() or #select(2,panel_rows(panel_mode)); if total<1 then return true end
  if panel_mode=='episodes' then panel_focus=clamp(panel_focus+delta,1,total)
  elseif panel_nav_focus then panel_section_focus=clamp(panel_section_focus+delta,1,#settings_sections)
  else local _,rows=panel_rows(panel_mode); panel_focus=move_to_actionable(rows,panel_focus,delta) end
  if panel_mode=='episodes' then panel_offset=clamp(panel_focus-2,1,math.max(1,total-4))
  else panel_offset=clamp(panel_focus-1,0,math.max(0,total-PANEL_ROWS)) end
  clear_overlays(); show(15); render(); return true
end
activate_panel_focus=function()
  if not panel_mode then return false end
  if panel_mode=='episodes' then load_item(episodes()[panel_focus],true)
  elseif panel_nav_focus then panel_mode=settings_sections[panel_section_focus].mode; panel_focus=first_panel_row(panel_mode); panel_offset=0; panel_nav_focus=false
  else local _,rows=panel_rows(panel_mode); run_row(rows[panel_focus]) end
  render()
  return true
end
set_panel_key_bindings=function(enabled)
  for _,name in ipairs({'yingji-panel-focus-up','yingji-panel-focus-down','yingji-panel-focus-left','yingji-panel-focus-right'}) do mp.remove_key_binding(name) end
  if not enabled then return end
  mp.add_forced_key_binding('UP','yingji-panel-focus-up',function() move_panel_focus(-1) end)
  mp.add_forced_key_binding('DOWN','yingji-panel-focus-down',function() move_panel_focus(1) end)
  mp.add_forced_key_binding('LEFT','yingji-panel-focus-left',function() if panel_mode~='episodes' then panel_nav_focus=true; panel_section_focus=settings_section_index(panel_mode); show(15); render() else move_panel_focus(-1) end end)
  mp.add_forced_key_binding('RIGHT','yingji-panel-focus-right',function() if panel_mode~='episodes' then panel_nav_focus=false; show(15); render() else move_panel_focus(1) end end)
end
local function toggle_panel(name)
  if name=='settings' then name='audio' end
  clear_overlays(); panel_mode=name; panel_opened_at=now(); panel_nav_focus=false; panel_section_focus=settings_section_index(name); panel_focus=name=='episodes' and current_episode_index() or first_panel_row(name); panel_offset=name=='episodes' and math.max(1,panel_focus-2) or math.max(0,panel_focus-1); set_panel_key_bindings(panel_mode=='episodes'); show(15); render()
end
local function set_volume_from_mouse(x, l)
  local volume=upper_controls(select(1,dimensions()),l)
  mp.set_property_native('volume',clamp((x-(volume.x+30))/(volume.w-40)*100,0,100))
end
local function click(event)
  if event and event.event=='up' then mouse_down=false; volume_dragging=false; progress_dragging=false; return end
  mouse_down=true
  local w,h=dimensions(); local x,y=mp.get_mouse_pos(); if not x or not y then return end
  if not visible() then show(); render() end
  local l=layout(w,h)
  for _,button in ipairs(top_buttons(w,l)) do if hit(x,y,button.x-20,15,button.x+20,57) then if button.name=='pin' then mp.commandv('cycle','ontop') elseif button.name=='min' then mp.commandv('set','window-minimized','yes') elseif button.name=='max' then mp.commandv('cycle','window-maximized') else mp.commandv('quit') end; show(); return end end
  if panel_mode=='episodes' then local cards=episode_cards(w,l); for _,card in ipairs(cards) do if hit(x,y,card.x,card.y,card.x+card.w,card.y+card.h) then load_item(card.item,true); return end end
  elseif panel_mode then
    local box=settings_panel_geometry(w,l)
    if hit(x,y,box.x+16,73,box.x+box.w-16,109) then local index=clamp(math.floor((x-(box.x+16))/((box.w-32)/#settings_sections))+1,1,#settings_sections); panel_mode=settings_sections[index].mode; panel_section_focus=index; panel_nav_focus=false; panel_focus=first_panel_row(panel_mode); panel_offset=0; show(15); render(); return end
    local detail_x=box.x+18
    if hit(x,y,detail_x,box.body_y,box.x+box.w-14,box.body_y+box.count*56) then local index=math.floor((y-box.body_y)/56)+1; local row=box.rows[panel_offset+index]; if row_actionable(row) then run_row(row); render() end; return end
  end
  local duration=tonumber((mp.get_property_native('duration'))) or 0; local track_x=l.console_x+86; local track_w=l.console_w-172
  if hit(x,y,track_x,l.progress_y-15,track_x+track_w,l.progress_y+15) and duration>0 then progress_dragging=true; mp.commandv('seek',duration*clamp((x-track_x)/track_w,0,1),'absolute'); show(); return end
  for _,button in ipairs(transport_buttons(w,l)) do if hit(x,y,button.x-24,l.center_y-28,button.x+24,l.center_y+28) then if button.name=='prev' then step_episode(-1) elseif button.name=='next' then step_episode(1) elseif button.name=='back' then mp.commandv('seek','-10','relative') elseif button.name=='forward' then mp.commandv('seek','10','relative') else mp.commandv('cycle','pause') end; show(); return end end
  local volume=upper_controls(w,l)
  if hit(x,y,volume.x,volume.y,volume.x+volume.w,volume.y+volume.h) then volume_dragging=true; set_volume_from_mouse(x,l); show(); return end
  for _,button in ipairs(utility_buttons(w,l)) do if hit(x,y,button.x,button.y,button.x+button.w,button.y+button.h) then if button.name=='fullscreen' then mp.commandv('cycle','fullscreen'); show(); render() else toggle_panel(button.name) end; return end end
  panel_nav_focus=false; clear_overlays(); show(); render()
end
local function scroll_panel(delta)
  if not panel_mode then return end
  if panel_mode=='episodes' then panel_offset=clamp(panel_offset+delta,1,math.max(1,#episodes()-4)) else local _,rows=panel_rows(panel_mode); panel_offset=clamp(panel_offset+delta,0,math.max(0,#rows-PANEL_ROWS)) end
  clear_overlays(); show(15); render()
end

mp.observe_property('mouse-pos','native',function(_,value) if value and (value.x~=mouse_x or value.y~=mouse_y) then mouse_x,mouse_y=value.x,value.y; if mouse_down then local w,h=dimensions(); local l=layout(w,h); if volume_dragging then set_volume_from_mouse(value.x,l); elseif progress_dragging then local duration=tonumber((mp.get_property_native('duration'))) or 0; local track_x=l.console_x+86; local track_w=l.console_w-172; if duration>0 then mp.commandv('seek',duration*clamp((value.x-track_x)/track_w,0,1),'absolute') end end end; show(); render() end end)
for _,name in ipairs({'pause','video-params','audio-params','cache-speed','track-list','aid','sid','secondary-sid','speed','volume','ontop','loop-file','audio-delay','sub-scale','sub-pos','sub-delay','sub-border-size','video-aspect-override','video-zoom','video-rotate','hwdec-current','current-vo','estimated-vf-fps','vo-drop-frame-count'}) do mp.observe_property(name,'native',render) end
mp.observe_property('time-pos','native',function(_,position) local rule=state.chapterRule or {}; position=tonumber(position) or 0; if state.chapterAutoSkip and rule.introEnd and not intro_skipped and position>0.5 and position<tonumber(rule.introEnd) then intro_skipped=true; mp.commandv('seek',tostring(rule.introEnd),'absolute+exact') end; if state.chapterAutoSkip and rule.outroStart and not outro_skipped and position>=tonumber(rule.outroStart) then outro_skipped=true; step_episode(1) end; render() end)
mp.observe_property('user-data/yj-player-update','string',function(_,raw) if not raw or raw=='' then return end; local ok,update=pcall(utils.parse_json,raw); if not ok or type(update)~='table' or (update.type~='danmaku' and update.type~='episode-data') then return end; if update.type=='episode-data' then state.chapterRule=update.chapterRule; state.chapterKey=update.chapterKey or state.chapterKey; intro_skipped=false; outro_skipped=false end; local old=danmaku_track(); if old then mp.commandv('sub-remove',tostring(old.id)) end; state.danmakuCount=tonumber(update.count) or 0; state.danmakuSourceInfo=type(update.sources)=='table' and update.sources or {}; if update.file and update.file~='' then mp.commandv('sub-add',update.file,'auto'); mp.add_timeout(.25,function() local track=danmaku_track(); if track and state.danmakuEnabled then mp.set_property('secondary-sid',tostring(track.id)) end; render() end) end; render() end)
mp.add_forced_key_binding('MBTN_LEFT','yingji-osc-click',click,{complex=true})
mp.add_forced_key_binding('ENTER','yingji-osc-enter',function() if panel_mode then activate_panel_focus() else mp.commandv('cycle','pause'); show(); render() end end)
mp.add_key_binding('UP','yingji-volume-up',function() if panel_mode then return end; mp.set_property_native('volume',clamp((tonumber(mp.get_property_native('volume')) or 100)+5,0,100)); show(); render() end)
mp.add_key_binding('DOWN','yingji-volume-down',function() if panel_mode then return end; mp.set_property_native('volume',clamp((tonumber(mp.get_property_native('volume')) or 100)-5,0,100)); show(); render() end)
mp.add_forced_key_binding('WHEEL_UP','yingji-panel-up',function() scroll_panel(-1) end)
mp.add_forced_key_binding('WHEEL_DOWN','yingji-panel-down',function() scroll_panel(1) end)
mp.add_key_binding('ESC','yingji-osc-close',function() if panel_mode=='episodes' then panel_mode='audio'; panel_nav_focus=false; set_panel_key_bindings(false); clear_overlays(); render() else mp.commandv('quit') end end)
mp.add_key_binding('SPACE','yingji-osc-pause',function() mp.commandv('cycle','pause'); show() end)
mp.add_key_binding('LEFT','yingji-osc-back',function() mp.commandv('seek','-10','relative'); show() end)
mp.add_key_binding('RIGHT','yingji-osc-forward',function() mp.commandv('seek','10','relative'); show() end)
mp.register_script_message('yingji-test-panel',toggle_panel)
mp.register_event('file-loaded',function() if pending_seek then local value=pending_seek; pending_seek=nil; mp.commandv('seek',value,'absolute+exact') end; apply_saved_track('audio',state.audioPreference); apply_saved_track('sub',state.subtitlePreference); local track=danmaku_track(); if track and state.danmakuEnabled then mp.set_property('secondary-sid',tostring(track.id)) end; show(4.5); render() end)
mp.register_event('start-file',function() panel_mode='audio'; panel_offset=0; panel_nav_focus=false; intro_skipped=false; outro_skipped=false; set_panel_key_bindings(false); clear_overlays(); show(15); render() end)
mp.register_event('shutdown',function() clear_overlays(); safe_overlay_command('overlay-remove',10) end)
mp.add_periodic_timer(.15,render)
