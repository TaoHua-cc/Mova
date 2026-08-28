-- 映迹播放器控制层：使用 mpv 原生命令实现 AI Player 风格空间布局。
local mp = require 'mp'
local assdraw = require 'mp.assdraw'
local visible_until, last_x, last_y = 0, -1, -1
local panel_open, controls_locked = false, false

local function now() return mp.get_time() end
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function esc(v) return tostring(v or ''):gsub('\\', '\\\\'):gsub('{', '\\{'):gsub('}', '\\}') end
local function fmt(v)
  v = math.max(0, math.floor(tonumber(v) or 0))
  return v >= 3600 and string.format('%d:%02d:%02d', math.floor(v / 3600), math.floor(v % 3600 / 60), v % 60) or string.format('%02d:%02d', math.floor(v / 60), v % 60)
end
local function text(ass, x, y, size, align, value, color, alpha, bold)
  ass:new_event(); ass:pos(x, y)
  ass:append(string.format('{\\an%d\\fs%.0f\\bord0\\shad0\\1c&H%s&\\1a&H%02X&%s}%s', align or 7, size, color or 'F8F8FA', alpha or 0, bold and '\\b1' or '', esc(value)))
end
local function rect(ass, x, y, w, h, color, alpha)
  ass:new_event(); ass:pos(0, 0); ass:append(string.format('{\\an7\\bord0\\shad0\\1c&H%s&\\1a&H%02X&}', color or '11131A', alpha or 0)); ass:draw_start(); ass:rect_cw(x, y, x + w, y + h); ass:draw_stop()
end
local function circle(ass, cx, cy, r, color, alpha)
  local k = r * .55228475; ass:new_event(); ass:pos(0, 0); ass:append(string.format('{\\an7\\bord0\\shad0\\1c&H%s&\\1a&H%02X&}', color or '181B22', alpha or 0)); ass:draw_start(); ass:move_to(cx, cy-r); ass:bezier_curve(cx+k,cy-r,cx+r,cy-k,cx+r,cy); ass:bezier_curve(cx+r,cy+k,cx+k,cy+r,cx,cy+r); ass:bezier_curve(cx-k,cy+r,cx-r,cy+k,cx-r,cy); ass:bezier_curve(cx-r,cy-k,cx-k,cy-r,cx,cy-r); ass:draw_stop()
end
local function pill(ass,x,y,w,h,color,alpha) local r=h/2; rect(ass,x+r,y,math.max(0,w-h),h,color,alpha); circle(ass,x+r,y+r,r,color,alpha); circle(ass,x+w-r,y+r,r,color,alpha) end
local function show(s) if not controls_locked then visible_until = now() + (s or 3.2) end end
local function visible() return controls_locked or panel_open or mp.get_property_native('pause', false) or now() < visible_until end
local function hit(x,y,l,t,r,b) return x>=l and x<=r and y>=t and y<=b end
local function hit_circle(x,y,cx,cy,r) return (x-cx)^2+(y-cy)^2<=r^2 end
local function action(command,...) mp.commandv(command,...); show(3.5); render() end
local function dimensions() local d=mp.get_property_native('osd-dimensions') or {}; local w,h=tonumber(d.w),tonumber(d.h); if not w or not h or w<=0 or h<=0 then w,h=mp.get_osd_size() end; return w,h end
local function layout(w,h) local e=math.max(18,math.floor(w*.01)); local bh=math.max(112,math.floor(h*.145)); return {edge=e,top_h=math.max(72,math.floor(h*.10)),bottom_h=bh,surface_y=h-bh,progress_y=h-bh+math.max(27,math.floor(bh*.20)),controls_y=h-math.max(37,math.floor(h*.047))} end
local function button(ass,cx,cy,r,label,selected) circle(ass,cx,cy,r,selected and 'F7F8FC' or '111217',selected and 0 or 18); text(ass,cx,cy+1,r>21 and 18 or 13,5,label,selected and '111217' or 'F7F8FC',0,true) end
local function panel_rows()
  local chapters,playlist=mp.get_property_native('chapter-list') or {},mp.get_property_native('playlist') or {}; local rows,heading={},#chapters>0 and '选集' or '播放列表'
  if #chapters>0 then for i,item in ipairs(chapters) do rows[#rows+1]={kind='chapter',index=i-1,title=item.title or ('第 '..i..' 节'),detail=fmt(item.time)} end else for i,item in ipairs(playlist) do rows[#rows+1]={kind='playlist',index=i-1,title=item.title or item.filename or ('播放项目 '..i),detail=''} end end
  if #rows==0 then rows[1]={kind='empty',title='当前媒体',detail='没有可切换项目'} end; return heading,rows
end

function render()
  local w,h=dimensions(); if not w or w<=0 or not visible() then mp.set_osd_ass(0,0,''); return end
  local l,ass=layout(w,h),assdraw.ass_new(); local duration,position=tonumber((mp.get_property_native('duration'))) or 0,tonumber((mp.get_property_native('time-pos'))) or 0; local paused,title=mp.get_property_native('pause',false),mp.get_property('media-title','映迹'); local video=mp.get_property_native('video-params') or {}; local res=tonumber(video.h) or 0; local quality=res>=2000 and '4K' or res>=1000 and '1080P' or res>0 and tostring(res)..'P' or 'HD'; local codec=mp.get_property('video-format',''):upper(); local progress=duration>0 and clamp(position/duration,0,1) or 0
  -- 顶部固定信息栏
  rect(ass,0,0,w,l.top_h,'000000',0); text(ass,l.edge,l.top_h*.47,22,7,'映','F7F8FC',0,true); pill(ass,l.edge+40,15,142,49,'111217',8); text(ass,l.edge+53,35,18,7,title,'FFFFFF',0,true); text(ass,l.edge+53,53,11,7,'正在播放','BDC1CB',18,false)
  local right=w-l.edge; pill(ass,right-238,24,76,26,'111217',12); text(ass,right-200,42,11,8,'播放中','EDF0F6',8,true); button(ass,right-142,37,17,'P',false); button(ass,right-100,37,17,'—',false); button(ass,right-58,37,17,'□',false); button(ass,right-18,37,17,'×',false)
  -- 底部控制面：图片保留原比例，控件层独立覆盖。
  rect(ass,0,l.surface_y,w,l.bottom_h,'000000',0); local bx,by=l.edge,l.surface_y+3; for _,badge in ipairs({quality,codec~='' and codec or 'Direct','60FPS','硬件解码'}) do local bw=math.max(38,#badge*7+16); pill(ass,bx,by,bw,20,'15171D',12); text(ass,bx+bw/2,by+14,10,8,badge,'F3F5F8',6,true); bx=bx+bw+5 end
  local box_x,box_w,box_h=l.edge,w-l.edge*2,44; pill(ass,box_x,l.progress_y,box_w,box_h,'07080C',18); local tx,tw,ty=box_x+58,box_w-116,l.progress_y+22; text(ass,box_x+12,l.progress_y+27,12,7,fmt(position),'FFFFFF',0,true); text(ass,box_x+box_w-12,l.progress_y+27,12,9,fmt(duration),'FFFFFF',0,true); rect(ass,tx,ty,tw,3,'737780',62); rect(ass,tx,ty,math.max(2,tw*progress),3,'F7F8FC',0); circle(ass,tx+tw*progress,ty+1.5,7,'F7F8FC',0)
  local cy,x=l.controls_y,l.edge+18; button(ass,x,cy,18,'|<',false); x=x+44; button(ass,x,cy,18,'10<',false); x=x+44; button(ass,x,cy,18,paused and '>' or '||',true); x=x+44; button(ass,x,cy,18,'>10',false); x=x+44; button(ass,x,cy,18,'>|',false)
  local rx=right-18; button(ass,rx,cy,18,'[]',false); rx=rx-42; button(ass,rx,cy,18,'⚙',false); rx=rx-42; button(ass,rx,cy,18,panel_open and '×' or '≡',false); rx=rx-42; button(ass,rx,cy,18,'CC',false); rx=rx-42; button(ass,rx,cy,18,'A',false); rx=rx-42; button(ass,rx,cy,18,'2x',false); rx=rx-50; pill(ass,rx-105,cy-18,122,36,'111217',12); text(ass,rx-93,cy+4,14,7,'VOL','FFFFFF',10,true); rect(ass,rx-58,cy-1,57,3,'838790',55); local volume=clamp((tonumber((mp.get_property_native('volume'))) or 100)/100,0,1); rect(ass,rx-58,cy-1,57*volume,3,'F6F7FA',0); circle(ass,rx-58+57*volume,cy+.5,7,'F6F7FA',0)
  if panel_open then
    local pw=math.min(math.floor(w*.32),480); local px,py,ph=w-l.edge-pw,l.top_h+20,math.min(h-l.top_h-l.bottom_h-36,560); pill(ass,px,py,pw,ph,'15181E',8); local heading,rows=panel_rows(); text(ass,px+22,py+30,19,7,heading,'FFFFFF',0,true); local row_y,row_h=py+49,math.max(45,math.min(63,(ph-62)/math.max(#rows,1)))
    for _,row in ipairs(rows) do if row_y+row_h>py+ph-7 then break end; local active=(row.kind=='chapter' and row.index==(mp.get_property_native('chapter') or -1)) or (row.kind=='playlist' and row.index==(mp.get_property_native('playlist-pos') or -1)); pill(ass,px+12,row_y,pw-24,row_h-7,active and 'EDF1F5' or '22262E',active and 6 or 22); text(ass,px+25,row_y+19,14,7,row.title,active and '15171C' or 'FFFFFF',0,true); text(ass,px+pw-25,row_y+19,12,9,row.detail,active and '3E4651' or 'B8BEC9',0,true); row_y=row_y+row_h end
  end
  mp.set_osd_ass(w,h,ass.text)
end

local function click()
  local w,h=dimensions(); local x,y=mp.get_mouse_pos(); if not x or not y then return end; if not visible() then show(); render(); return end
  local l=layout(w,h); local right,cy=w-l.edge,l.controls_y
  if hit_circle(x,y,right-18,37,19) then action('quit') elseif hit_circle(x,y,right-58,37,19) then action('cycle','fullscreen') elseif hit_circle(x,y,right-100,37,19) then action('set','window-minimized','yes') elseif hit_circle(x,y,right-142,37,19) then action('cycle','ontop')
  elseif hit(x,y,l.edge+58,l.progress_y-8,w-l.edge-58,l.progress_y+50) then local duration=tonumber((mp.get_property_native('duration'))) or 0; if duration>0 then action('seek',duration*clamp((x-(l.edge+58))/(w-l.edge*2-116),0,1),'absolute') end
  elseif hit_circle(x,y,l.edge+18,cy,20) then action('playlist-prev','force') elseif hit_circle(x,y,l.edge+62,cy,20) then action('seek','-10','relative') elseif hit_circle(x,y,l.edge+106,cy,20) then action('cycle','pause') elseif hit_circle(x,y,l.edge+150,cy,20) then action('seek','10','relative') elseif hit_circle(x,y,l.edge+194,cy,20) then action('playlist-next','force')
  else
    local rx=right-18
    if hit_circle(x,y,rx,cy,20) then action('cycle','fullscreen') elseif hit_circle(x,y,rx-42,cy,20) then controls_locked=not controls_locked; show(5); render() elseif hit_circle(x,y,rx-84,cy,20) then panel_open=not panel_open; show(12); render() elseif hit_circle(x,y,rx-126,cy,20) then action('cycle','sub-visibility') elseif hit_circle(x,y,rx-168,cy,20) then action('cycle-values','audio','no','auto') elseif hit_circle(x,y,rx-210,cy,20) then action('cycle-values','speed','1','1.25','1.5','2') elseif hit(x,y,rx-155,cy-21,rx-33,cy+21) then mp.set_property_native('volume',clamp((x-(rx-155))/57*100,0,100)); show(3.5); render()
    elseif panel_open then local pw=math.min(math.floor(w*.32),480); local px,py,ph=w-l.edge-pw,l.top_h+20,math.min(h-l.top_h-l.bottom_h-36,560); if hit(x,y,px,py+49,px+pw,py+ph) then local _,rows=panel_rows(); local row_h=math.max(45,math.min(63,(ph-62)/math.max(#rows,1))); local row=rows[math.floor((y-(py+49))/row_h)+1]; if row and row.kind=='chapter' then action('set','chapter',row.index) elseif row and row.kind=='playlist' then action('playlist-play-index',row.index) end end else show(); render() end
  end
end

mp.observe_property('mouse-pos','native',function(_,v) if v and (v.x~=last_x or v.y~=last_y) then last_x,last_y=v.x,v.y; show() end end)
mp.observe_property('time-pos','native',render); mp.observe_property('pause','native',function() show(); render() end); mp.observe_property('chapter','native',render); mp.observe_property('playlist-pos','native',render); mp.register_event('video-reconfig',render)
mp.add_forced_key_binding('MBTN_LEFT','yingji-osc-click',click); mp.add_key_binding('ESC','yingji-osc-close',function() mp.commandv('quit') end); mp.add_key_binding('SPACE','yingji-osc-pause',function() action('cycle','pause') end); mp.add_key_binding('LEFT','yingji-osc-back',function() action('seek','-10','relative') end); mp.add_key_binding('RIGHT','yingji-osc-forward',function() action('seek','10','relative') end); mp.add_periodic_timer(.1,render); mp.register_event('file-loaded',function() panel_open=false; controls_locked=false; show(4.5); render() end)
